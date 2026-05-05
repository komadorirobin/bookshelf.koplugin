-- book_repository.lua
-- Unified Book record source over KOReader's ReadHistory, ReadCollection,
-- BookInfoManager, DocSettings, and (optionally) statistics.koplugin.
--
-- Design contract: this module produces Book records only — no widget code,
-- no UI imports. All external KOReader modules are reached through getter
-- functions so that pure-Lua tests can stub them via package.loaded before
-- require() is called.

local Repo = {}

-- ─── Module-local helpers ────────────────────────────────────────────────────

-- Split a comma-separated author string into a trimmed array, or return nil.
local function splitAuthors(s)
    if not s or s == "" then return nil end
    local t = {}
    for part in s:gmatch("([^,]+)") do
        t[#t + 1] = part:match("^%s*(.-)%s*$")  -- trim whitespace
    end
    return #t > 0 and t or nil
end

-- Supported e-book extensions (used in both getCurrent and walkBooks).
local SUPPORTED_EXT = {
    epub=true, pdf=true, mobi=true, azw3=true, fb2=true,
    cbz=true, cbr=true, txt=true, md=true, html=true, htm=true, djvu=true,
}

-- ─── Lazy module accessors ───────────────────────────────────────────────────
-- Never require() at module top-level; tests stub via package.loaded.

local function getReadHistory()  return require("readhistory") end
local function getCollections()  return require("readcollection") end
local function getBookInfoMgr()  return require("bookinfomanager") end
local function getDocSettings()  return require("docsettings") end

-- ─── buildBook ────────────────────────────────────────────────────────────────
-- Constructs a Book record for a given filepath.
-- Fields follow spec §5.1. Metadata from BookInfoManager; position from
-- DocSettings. Enrichment (stats) is a separate step (see enrichStats).
--
-- Series number strategy: BookInfoManager may return both info.series
-- (formatted as "<name> #<n>") and info.series_index (bare number). We prefer
-- series_index when present to avoid fragile string parsing; fall back to
-- parsing the formatted series string for compatibility with older caches.

-- buildBookMeta(filepath) — BookInfoManager-only Book record (no DocSettings).
-- Used by every shelf-rendering path (getRecent / getLatest / getFavorites /
-- getSeriesGroups), all of which only need cover/title/author/series fields.
-- Skipping the DocSettings sidecar read is the dominant per-rebuild saving on
-- libraries >100 books — DocSettings:open() does a Lua-parse from disk per
-- file. Use buildBook (below) when DocSettings fields (page_num, book_pct,
-- last_xp) are actually needed (i.e. the hero card and the previewed book).
function Repo.buildBookMeta(filepath)
    if not filepath then return nil end
    local bim  = getBookInfoMgr()
    local info = bim:getBookInfo(filepath, true) or {}

    -- Parse series info.
    -- KOReader's BookInfoManager returns info.series as "<name> #<n>" and
    -- info.series_index as the bare number when the cache is populated.
    -- We use series_index when available; otherwise parse the formatted string.
    local series_name, series_num
    if info.series then
        series_name = info.series:gsub(" #%d+$", "")
        series_num  = info.series:match(" #(%d+)$")
    end
    if info.series_index then
        series_num = tostring(info.series_index)
    end

    local authors = splitAuthors(info.authors)
    return {
        filepath    = filepath,
        filename    = (filepath:match("([^/]+)$") or filepath):gsub("%.[^.]+$", ""),
        format      = (filepath:match("%.([^.]+)$") or ""):upper(),
        title       = info.title,
        author      = authors and authors[1] or nil,
        authors     = authors,
        series      = info.series,
        series_name = series_name,
        series_num  = series_num,
        cover_bb    = info.cover_bb,
        has_cover   = info.has_cover and not info.ignore_cover,
        lang        = info.language,
        description = info.description,
        page_count  = info.pages,
    }
end

function Repo.buildBook(filepath)
    local book = Repo.buildBookMeta(filepath)
    if not book then return nil end
    local ds = getDocSettings():open(filepath)
    book.page_num = ds:readSetting("last_page")
    book.book_pct = ds:readSetting("percent_finished")
    book.last_xp  = ds:readSetting("last_xpointer")
    return book
end

-- ─── getCurrent ──────────────────────────────────────────────────────────────
-- Returns the Book record for the last opened file, or nil if none.

function Repo.getCurrent()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile then return nil end
    -- Only accept supported book formats. Otherwise hero card stays empty —
    -- avoids stale PNGs / config files / random opened-once non-books from
    -- taking the hero slot.
    local ext = lastfile:match("%.([^.]+)$")
    if not ext or not SUPPORTED_EXT[ext:lower()] then return nil end
    return Repo.buildBook(lastfile)
end

-- ─── getRecent ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadHistory.hist, in order
-- (ReadHistory keeps hist sorted newest-first already). No exclusion —
-- the active book stays visible in the shelf, and the BookshelfWidget
-- highlights the previewed spine instead so the user can tell which one
-- the hero is currently displaying. Earlier iterations excluded lastfile
-- to avoid hero+slot-1 duplication; that exchange wasn't worth the
-- shelves jumping around as the user browsed previews.

function Repo.getRecent(limit)
    local rh  = getReadHistory()
    local out = {}
    for i = 1, #rh.hist do
        local entry = rh.hist[i]
        -- Shelf path: BIM-only meta is enough (no DocSettings needed).
        local book = Repo.buildBookMeta(entry.file)
        if book then
            book.last_read_time = entry.time
            out[#out + 1] = book
            if #out >= (limit or 8) then break end
        end
    end
    return out
end

-- ─── getLatest ───────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records, sorted newest-by-mtime first, from a
-- recursive filesystem walk rooted at G_reader_settings `home_dir`.
-- Walk depth is capped by `bookshelf_latest_walk_depth` setting (default 3).
-- Results are NOT memoised here — caching is a BookshelfWidget-level concern.

-- KOReader ships LFS as `libs/libkoreader-lfs` and that's the only path that
-- works inside the plugin loader. The unprefixed `require("lfs")` resolves
-- only in the test harness (where we stub package.loaded.lfs) and fails at
-- runtime — which is what crashed the chip switch on first use.
-- ─── Walk cache ──────────────────────────────────────────────────────────────
-- walkBooks is the dominant cost in BookshelfWidget:_rebuild for any
-- non-trivial library: a recursive lfs scan plus per-file mtime stats. Both
-- getLatest and getSeriesGroups call it, and both fire on every chip switch
-- and page flip. We memoise the candidate list keyed by (home, depth) with a
-- short TTL so back-to-back rebuilds reuse the work.
--
-- Invalidation: TTL covers the steady state. main.lua's onCloseDocument hook
-- calls Repo.invalidateWalkCache() so a session that closes a book and
-- returns to Bookshelf picks up any sideloaded / moved files immediately.
local WALK_CACHE_TTL = 30  -- seconds
local _walk_cache = {}     -- { [key] = { list = {...}, expires_at = number } }

-- Series-groups cache. The walk-cache covers the lfs.dir + per-file mtime
-- sweep, but getSeriesGroups also iterates EVERY candidate calling
-- buildBookMeta — that's a BookInfoManager (SQLite) lookup per book, the
-- dominant cost on the Series chip for libraries above ~1k books.
-- Memoise the post-iteration result (full pre-slice list) keyed on the
-- same (home, depth) the walk uses, with a matching TTL. Invalidation
-- piggy-backs on invalidateWalkCache so onCloseDocument naturally
-- refreshes both — a just-read book's read-time bubble-up still lands
-- on the next chip rebuild.
local SERIES_CACHE_TTL = WALK_CACHE_TTL
local _series_cache    = {}  -- { [key] = { groups = {...}, expires_at = number } }

function Repo.invalidateWalkCache()
    _walk_cache   = {}
    _series_cache = {}
end

function Repo.invalidateSeriesCache()
    _series_cache = {}
end

local function walkBooks(root, depth, out, current_depth)
    current_depth = current_depth or 0
    if current_depth > depth then return end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.dir then return end

    -- Guard against permission errors / missing dirs raised by lfs.dir(root).
    -- lfs.dir returns (iterator, dir_obj); both must be passed to the for
    -- loop or lfs raises "directory metatable expected, got nil" on the first
    -- step. pcall returns (ok, ret1, ret2, …) — capture both real returns.
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok or type(iter) ~= "function" then return end

    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local fp   = root .. "/" .. entry
            local mode = lfs.attributes(fp, "mode")
            if mode == "directory" then
                walkBooks(fp, depth, out, current_depth + 1)
            elseif mode == "file" then
                local ext = entry:match("%.([^.]+)$")
                if ext and SUPPORTED_EXT[ext:lower()] then
                    out[#out + 1] = { fp = fp, mtime = lfs.attributes(fp, "modification") or 0 }
                end
            end
        end
    end
end

-- Returns a shallow copy of the cached candidate list for (home, depth).
-- Walks fresh on miss/expiry. The copy is so callers (e.g. getLatest)
-- can sort in place without mutating the cached canonical order.
local function cachedWalk(home, depth)
    local key = (home or "/") .. ":" .. tostring(depth or 0)
    local now = os.time()
    local entry = _walk_cache[key]
    if not entry or entry.expires_at <= now then
        local fresh = {}
        walkBooks(home, depth, fresh)
        entry = { list = fresh, expires_at = now + WALK_CACHE_TTL }
        _walk_cache[key] = entry
    end
    local copy = {}
    for i = 1, #entry.list do copy[i] = entry.list[i] end
    return copy
end

function Repo.getLatest(limit)
    local home       = G_reader_settings:readSetting("home_dir") or "/"
    local depth      = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local candidates = cachedWalk(home, depth)
    table.sort(candidates, function(a, b) return a.mtime > b.mtime end)
    local out = {}
    for i = 1, math.min(limit or 8, #candidates) do
        local book = Repo.buildBookMeta(candidates[i].fp)
        if book then
            book.added_time = candidates[i].mtime
            out[#out + 1] = book
        end
    end
    return out
end

-- ─── getAll / findFirstBookIn ────────────────────────────────────────────────
-- Folder-aware listing for the "All" chip. Delegates to KOReader's
-- FileChooser:genItemTableFromPath so the user's collate, reverse_collate,
-- collate_mixed and book status filter are honoured for free — no need to
-- maintain a parallel sort/filter pipeline. Output is converted into our
-- internal item shape: bare Book records for files, folder records for
-- directories. Folder records carry { kind = "folder", path, label,
-- first_book } where first_book is the first usable book found by walking
-- the directory tree (bounded depth) so the FolderStack widget has a cover
-- to display on the spine.

-- Walk into `path` to find the first book metadata-buildable via the
-- BIM, with a bounded recursion depth to keep chip-render time predictable.
-- Files in the current dir are checked before recursing into subdirs;
-- entries are sorted alphabetically so the result is deterministic.
function Repo.findFirstBookIn(path, max_depth)
    max_depth = max_depth or 3
    if max_depth < 0 then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local entries = {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return nil end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." and not f:match("^%.") then
            entries[#entries + 1] = f
        end
    end
    table.sort(entries)
    -- Pass 1: files at this level. Use SUPPORTED_EXT directly rather
    -- than FileChooser:show_file so we don't need a FileChooser self.
    for _, f in ipairs(entries) do
        local fp = path .. "/" .. f
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "file" then
            local ext = f:match("%.([^.]+)$")
            if ext and SUPPORTED_EXT[ext:lower()] then
                local b = Repo.buildBookMeta(fp)
                if b then return b end
            end
        end
    end
    -- Pass 2: descend into subdirs (depth-limited)
    for _, f in ipairs(entries) do
        local fp = path .. "/" .. f
        local attr = lfs.attributes(fp)
        if attr and attr.mode == "directory" then
            local found = Repo.findFirstBookIn(fp, max_depth - 1)
            if found then return found end
        end
    end
    return nil
end

function Repo.getAll(path, limit)
    path = path or G_reader_settings:readSetting("home_dir") or "/"
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok or not FileChooser then return {} end
    local raw_items
    ok, raw_items = pcall(function() return FileChooser:genItemTableFromPath(path) end)
    if not ok or type(raw_items) ~= "table" then return {} end

    local out = {}
    for _, item in ipairs(raw_items) do
        -- FileChooser injects a "../ ⬆" go-up entry and an optional
        -- "Long-press here to choose current folder" entry. Skip both —
        -- bookshelf has its own back-navigation (breadcrumb / east-swipe).
        if not item.is_go_up and item.path and item.path ~= "" and item.text
                and not (item.text and item.text:find("Long%-press here")) then
            if item.is_file then
                local b = Repo.buildBookMeta(item.path)
                if b then out[#out + 1] = b end
            elseif item.attr and item.attr.mode == "directory" then
                out[#out + 1] = {
                    kind       = "folder",
                    path       = item.path,
                    label      = item.text,
                    first_book = Repo.findFirstBookIn(item.path, 3),
                }
            end
            if limit and #out >= limit then break end
        end
    end
    return out
end

-- ─── getFavorites ────────────────────────────────────────────────────────────
-- Returns up to `limit` Book records from ReadCollection favorites collection,
-- sorted by access time descending (most recently accessed first).

function Repo.getFavorites(limit)
    local rc    = getCollections()
    local items = {}
    for _file, item in pairs(rc.coll and rc.coll.favorites or {}) do
        items[#items + 1] = item
    end
    table.sort(items, function(a, b)
        return (a.attr and a.attr.access or 0) > (b.attr and b.attr.access or 0)
    end)
    local out = {}
    for i = 1, math.min(limit or 8, #items) do
        local book = Repo.buildBookMeta(items[i].file)
        if book then
            book.in_favorites = true
            out[#out + 1] = book
        end
    end
    return out
end

-- ─── getSeriesGroups ─────────────────────────────────────────────────────────
-- Returns up to `limit` series groups derived from a filesystem walk of the
-- user's library (so unread books in a series still show up, not only ones
-- in ReadHistory). Each group is { series_name, books, latest } where books
-- are sorted by series_num ascending. Groups are sorted by most recent
-- activity descending — read-time from ReadHistory when available, else the
-- file's mtime as a fallback so newly-added unread series still surface.
-- Books without a series_name are excluded.

-- Hydrate a cached series shape into a renderable group: rebuild every
-- Book record fresh via buildBookMeta. A previous version of the cache
-- stashed Book objects directly, but their cover_bb fields are owned by
-- ImageWidget and freed after each paint — reusing cached Books segv'd
-- on subsequent renders ("cover image corruption / crash going back out
-- of a series"). Caching the shape (filepath list + sort metadata) and
-- rebuilding Books on read keeps the cover_bb lifetime safe while still
-- skipping the lfs walk + the sort/group pass.
local function hydrateSeriesShape(shape)
    local books = {}
    for _, fp in ipairs(shape.filepaths) do
        local b = Repo.buildBookMeta(fp)
        if b then books[#books + 1] = b end
    end
    return {
        series_name = shape.series_name,
        books       = books,
        latest      = shape.latest,
    }
end

function Repo.getSeriesGroups(limit)
    local home  = G_reader_settings:readSetting("home_dir") or "/"
    local depth = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    local key   = (home or "/") .. ":" .. tostring(depth or 0)
    local now   = os.time()

    -- Cache fast path: filepaths + sort metadata are stable across
    -- renders; Books get rehydrated each read so cover_bbs are fresh.
    local cached = _series_cache[key]
    if cached and cached.expires_at > now then
        local out = {}
        for i = 1, math.min(limit or 4, #cached.groups) do
            out[i] = hydrateSeriesShape(cached.groups[i])
        end
        return out
    end

    -- Build a filepath → read-time map so the series sort still favours
    -- series you've actually been reading lately.
    local rh        = getReadHistory()
    local read_time = {}
    for _, entry in ipairs(rh.hist) do
        local t = entry.time or 0
        if t > (read_time[entry.file] or 0) then
            read_time[entry.file] = t
        end
    end

    local candidates = cachedWalk(home, depth)

    local groups = {}  -- keyed by series_name
    local order  = {}  -- preserves insertion order for deterministic tie-break
    for _, c in ipairs(candidates) do
        -- Use the BIM-only meta build: this loop runs over EVERY candidate
        -- in the library walk (potentially hundreds of files), and we don't
        -- need DocSettings here. The full buildBook (sidecar parse) was the
        -- dominant per-rebuild cost on the Series chip; meta-only is just
        -- an in-memory BookInfoManager lookup.
        local book = Repo.buildBookMeta(c.fp)
        if book and book.series_name then
            local sname = book.series_name
            if not groups[sname] then
                groups[sname] = { series_name = sname, books = {}, latest = 0, _seen = {} }
                order[#order + 1] = sname
            end
            if not groups[sname]._seen[book.filepath] then
                groups[sname]._seen[book.filepath] = true
                groups[sname].books[#groups[sname].books + 1] = book
            end
            local t = read_time[book.filepath] or c.mtime or 0
            if t > groups[sname].latest then
                groups[sname].latest = t
            end
        end
    end
    -- Flatten to list and sort by most recent activity.
    local list = {}
    for _, k in ipairs(order) do list[#list + 1] = groups[k] end
    table.sort(list, function(a, b) return a.latest > b.latest end)
    -- Within each group, sort books by series_num ascending. Also remove _seen helper.
    for _, g in ipairs(list) do
        g._seen = nil
        table.sort(g.books, function(a, b)
            return (tonumber(a.series_num) or 0) < (tonumber(b.series_num) or 0)
        end)
    end

    -- Stash the SHAPE (filepaths + sort metadata) — never the Book
    -- records themselves. That avoids the use-after-free on the
    -- ImageWidget-owned cover_bbs that books carry.
    local shapes = {}
    for _, group in ipairs(list) do
        local fps = {}
        for _, b in ipairs(group.books) do fps[#fps + 1] = b.filepath end
        shapes[#shapes + 1] = {
            series_name = group.series_name,
            filepaths   = fps,
            latest      = group.latest,
        }
    end
    _series_cache[key] = { groups = shapes, expires_at = now + SERIES_CACHE_TTL }

    local out = {}
    for i = 1, math.min(limit or 4, #list) do out[i] = list[i] end
    return out
end

-- ─── enrichStats ─────────────────────────────────────────────────────────────
-- Mutates `book` in-place with statistics fields from readerstatistics.
-- Graceful no-op when the statistics plugin is absent or its API method is nil.
--
-- CONTRACT: ReaderStatistics:getBookStat(filepath) is the intended public API
-- boundary for v0.1. As of 2026-05, upstream KOReader does not expose this
-- exact method — getBookStat() does not exist in the KOReader codebase.
-- The pcall + nil-guard means we fall through silently and all stat-based
-- tokens auto-hide via Tokens.isEmpty. When the upstream API stabilises,
-- update this single function — that's why the boundary is isolated here.

-- enrichStats — fill the book record with reading-statistics fields.
-- Queries the statistics plugin's SQLite DB directly: ReaderStatistics
-- doesn't expose a clean filepath-keyed API, only an integer id_book and
-- KeyValuePage-shaped output for its Reader-context UI. We compute the
-- file's partial MD5 (the same key the stats plugin uses) and read the
-- rolled-up fields from the `book` table plus a couple of derived stats
-- from `page_stat_data` for days-reading / pages-per-day / speed.
--
-- Per-filepath cache with TTL: fires on every hero rebuild + every preview
-- tap, and the SQLite open + 3 prepared queries adds up across an
-- interactive session. Cached fields are mutated into the passed-in book
-- on subsequent calls within TTL. Invalidate via Repo.invalidateStatsCache()
-- (called from onCloseDocument so freshly-read pages surface immediately).
local STATS_CACHE_TTL = 30  -- seconds
local _stats_cache = {}     -- filepath → { fields = {...}, expires_at = number }
local STATS_FIELDS = {
    "book_read_time_seconds", "book_pages_read", "days_reading_book",
    "pages_per_day", "speed_pph", "book_time_left_minutes",
}

function Repo.invalidateStatsCache(filepath)
    if filepath then _stats_cache[filepath] = nil
    else _stats_cache = {} end
end

function Repo.enrichStats(book)
    if not book or not book.filepath then return end
    local now = os.time()
    local cached = _stats_cache[book.filepath]
    if cached and cached.expires_at > now then
        for _, k in ipairs(STATS_FIELDS) do book[k] = cached.fields[k] end
        return
    end
    -- ReaderStatistics keys books by `partial_md5_checksum` stored in the
    -- DocSettings sidecar (statistics/main.lua:2740). Read from there
    -- first; fall back to recomputing only if the sidecar is missing.
    local md5
    local ok_ds, ds = pcall(function() return getDocSettings():open(book.filepath) end)
    if ok_ds and ds and ds.readSetting then
        md5 = ds:readSetting("partial_md5_checksum")
    end
    if not md5 then
        local ok_util, util = pcall(require, "util")
        if ok_util and util and util.partialMD5 then
            md5 = util.partialMD5(book.filepath)
        end
    end
    if not md5 then return end

    local ok_ds, DataStorage = pcall(require, "datastorage")
    local ok_sq, SQ3         = pcall(require, "lua-ljsqlite3/init")
    if not (ok_ds and DataStorage and ok_sq and SQ3) then return end
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_conn, conn = pcall(SQ3.open, db_path)
    if not ok_conn or not conn then return end

    -- Roll-ups from the book table (kept in sync by ReaderStatistics).
    local id_book, total_read_time, total_read_pages, pages_total
    local ok_q, err = pcall(function()
        local stmt = conn:prepare(
            "SELECT id, total_read_time, total_read_pages, pages "
            .. "FROM book WHERE md5 = ? LIMIT 1")
        local row = stmt:reset():bind(md5):step()
        stmt:close()
        if row then
            id_book          = tonumber(row[1])
            total_read_time  = tonumber(row[2]) or 0
            total_read_pages = tonumber(row[3]) or 0
            pages_total      = tonumber(row[4]) or 0
        end
    end)
    if not ok_q or not id_book then conn:close(); return end

    -- Days-reading + first-open + last-page from page_stat_data, same query
    -- shape as ReaderStatistics:getBookStat.
    local total_days, first_open
    pcall(function()
        local stmt = conn:prepare(
            "SELECT count(*) FROM ("
            .. "  SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d "
            .. "  FROM page_stat_data WHERE id_book = ? GROUP BY d)")
        local row = stmt:reset():bind(id_book):step()
        stmt:close()
        total_days = row and tonumber(row[1]) or 0
    end)
    pcall(function()
        local stmt = conn:prepare(
            "SELECT min(start_time) FROM page_stat_data WHERE id_book = ?")
        local row = stmt:reset():bind(id_book):step()
        stmt:close()
        first_open = row and tonumber(row[1]) or nil
    end)
    conn:close()

    -- Roll-up derived fields. Defensive math: pages_total/total_read_pages
    -- can be 0 on a freshly-tracked book; guard divisions.
    book.book_read_time_seconds = total_read_time
    book.book_pages_read        = total_read_pages
    book.days_reading_book      = total_days
    if total_days > 0 then
        book.pages_per_day = math.floor(total_read_pages / total_days + 0.5)
    end
    if total_read_time > 0 then
        -- Speed in pages per hour.
        book.speed_pph = math.floor(total_read_pages * 3600 / total_read_time + 0.5)
    end
    -- Time-left estimate: pages remaining × current avg time per page.
    if total_read_pages > 0 and pages_total > 0 then
        local pages_left = math.max(0, pages_total - total_read_pages)
        local avg_per_page = total_read_time / total_read_pages
        book.book_time_left_minutes = math.floor(pages_left * avg_per_page / 60 + 0.5)
    end

    -- Snapshot computed fields into the cache.
    local snapshot = {}
    for _, k in ipairs(STATS_FIELDS) do snapshot[k] = book[k] end
    _stats_cache[book.filepath] = { fields = snapshot, expires_at = now + STATS_CACHE_TTL }
end

return Repo
