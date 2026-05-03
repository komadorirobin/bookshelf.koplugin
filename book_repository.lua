-- book_repository.lua
-- Unified Book record source over KOReader's ReadHistory, ReadCollection,
-- BookInfoManager, DocSettings, and (optionally) statistics.koplugin.
--
-- Design contract: this module produces Book records only — no widget code,
-- no UI imports. All external KOReader modules are reached through getter
-- functions so that pure-Lua tests can stub them via package.loaded before
-- require() is called.

local Repo = {}

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

function Repo.buildBook(filepath)
    if not filepath then return nil end
    local bim  = getBookInfoMgr()
    local info = bim:getBookInfo(filepath, true) or {}
    local ds   = getDocSettings():open(filepath)

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
        -- Prefer the discrete numeric index over the parsed string.
        series_num = tostring(info.series_index)
    end

    local book = {
        filepath    = filepath,
        filename    = (filepath:match("([^/]+)$") or filepath):gsub("%.[^.]+$", ""),
        format      = (filepath:match("%.([^.]+)$") or ""):upper(),
        title       = info.title,
        -- authors field in BookInfoManager is a comma-separated string.
        author      = info.authors and info.authors:match("^([^,]+)") or nil,
        authors     = info.authors and { info.authors:match("^([^,]+)") } or nil,
        series      = info.series,
        series_name = series_name,
        series_num  = series_num,
        cover_bb    = info.cover_bb,
        has_cover   = info.has_cover and not info.ignore_cover,
        lang        = info.language,
        page_num    = ds:readSetting("last_page"),
        page_count  = info.pages,
        book_pct    = ds:readSetting("percent_finished"),
        last_xp     = ds:readSetting("last_xpointer"),
    }
    return book
end

-- ─── getCurrent ──────────────────────────────────────────────────────────────
-- Returns the Book record for the last opened file, or nil if none.

function Repo.getCurrent()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile then return nil end
    return Repo.buildBook(lastfile)
end

return Repo
