
-- After the lib/ reorg, internal requires resolve as "lib/bookshelf_X".
-- Add the plugin root to package.path so `require("lib/bookshelf_X")`
-- finds the file at <plugin_root>/lib/bookshelf_X.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

-- Hardcover's enrichment/ratings caches are SQLite-backed (v2.4.2+); install
-- the in-memory cache fake BEFORE any module that loads bookshelf_hardcover, so
-- buildBookMeta/getAll enrichment reads exercise the real cache paths.
local hccache = dofile("tests/_helpers.lua").install_hardcover_cache_fake()

-- Hardcover.enrichBook/applyMetadata only run when the plugin is live, i.e.
-- Hardcover.isAvailable() -- which pcall-requires the external plugin's API
-- module (absent in CI). Stub it (with a query fn, memoised true on first call)
-- BEFORE bookshelf_hardcover is first required, so the enrichment tests below
-- exercise the plugin-present path. Without this the availability gate (v3.8.8)
-- suppresses all enrichment and the description/cover assertions fail.
package.loaded["hardcover/lib/hardcover_api"] = { query = function() return nil end }

package.loaded["readhistory"] = { hist = {} }
package.loaded["readcollection"] = { coll = { favorites = {} }, default_collection_name = "favorites" }
package.loaded["bookinfomanager"] = {
    getBookInfo = function(_self, fp, _with_cover)
        return _G._test_bim_data and _G._test_bim_data[fp] or nil
    end,
}
package.loaded["docsettings"] = {
    open = function(_self, fp)
        return setmetatable({}, { __index = function(_, k)
            if k == "readSetting" then return function(_, key)
                return _G._test_docsettings_data and _G._test_docsettings_data[fp]
                    and _G._test_docsettings_data[fp][key]
            end end
        end })
    end,
    -- enrichBook's use_cover path looks for a custom .sdr cover; none in tests,
    -- so it falls back to the cached download path.
    findCustomCoverFile = function() return nil end,
    -- KOReader resolves the sidecar wherever the "Book metadata location"
    -- setting puts it (alongside the book, a central dir, or by hash). A book
    -- has a sidecar iff we set up DocSettings data for it -- independent of any
    -- sibling .sdr the lfs stub reports. Models the "dir"/"hash" case (#117).
    hasSidecarFile = function(_self, fp)
        return _G._test_docsettings_data and _G._test_docsettings_data[fp] ~= nil or false
    end,
}
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(fp, key)
        if key == "modification" then
            return _G._test_mtime and _G._test_mtime[fp] or 0
        end
    end,
}
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end, err = function() end }

-- ISO language name lookup used by bookshelf_lang (required by the repo at
-- load). 3-letter code -> English name, with the real module's code fallback.
package.loaded["ui/data/isolanguage"] = {
    getLocalizedLanguage = function(_self, iso3)
        local N = { eng = "English", deu = "German", fra = "French",
                    jpn = "Japanese", spa = "Spanish", zho = "Chinese" }
        return N[iso3] or iso3
    end,
}

-- BookshelfSettings stub: reads from the same _test_settings table as
-- the G_reader_settings stub, but transparently re-prefixes keys with
-- "bookshelf_". Lets existing tests keep using bookshelf_X keys in
-- _test_settings while production code reads short keys via the store.
local _store_generation = 1
package.loaded["lib/bookshelf_settings_store"] = {
    read   = function(key, default)
        local v = _G._test_settings and _G._test_settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save   = function(key, value)
        _G._test_settings = _G._test_settings or {}
        _G._test_settings["bookshelf_" .. key] = value
        _store_generation = _store_generation + 1
    end,
    delete = function(key)
        if _G._test_settings then _G._test_settings["bookshelf_" .. key] = nil end
        _store_generation = _store_generation + 1
    end,
    flush  = function() end,
    generation = function() return _store_generation end,
    isTrue = function(key)
        return _G._test_settings and _G._test_settings["bookshelf_" .. key] == true
    end,
    nilOrTrue = function(key)
        if not _G._test_settings then return true end
        local v = _G._test_settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}
_G.G_reader_settings = setmetatable({}, {
    __index = function(_, k)
        if k == "readSetting" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key]
            end
        end
        if k == "isTrue" then
            return function(_, key)
                return _G._test_settings and _G._test_settings[key] == true
            end
        end
        return nil
    end,
})


-- ── the bit this suite is actually about ────────────────────────────────────
-- A fake Persist, so the walk snapshot can be written by one module instance
-- and read by the next. Repo is loaded with dofile(), so re-loading it gives a
-- fresh module with an empty in-memory walk cache: that IS a restart, which is
-- the only condition under which the snapshot does anything.
local disk = { data = nil, files = {}, saves = 0, loads = 0, deletes = 0 }
package.loaded["persist"] = {
    new = function(_self, opts)
        return {
            load = function() disk.loads = disk.loads + 1; return disk.files[opts.path] end,
            save = function(_s, value)
                disk.saves = disk.saves + 1
                disk.data, disk.files[opts.path] = value, value
                return true
            end,
            delete = function()
                disk.deletes = disk.deletes + 1
                if disk.data == disk.files[opts.path] then disk.data = nil end
                disk.files[opts.path] = nil
                return true
            end,
        }
    end,
}
-- The hardcover cache fake installs a datastorage with only getSettingsDir;
-- the snapshot path needs getDataDir too.
package.loaded["datastorage"] = {
    getDataDir     = function() return "/tmp/bookshelf-walk-test" end,
    getSettingsDir = function() return "/tmp/bookshelf-walk-test" end,
}

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

-- One tree, one mtime table, and a counter for how many directories the walk
-- actually reads. That counter is the whole point: a snapshot that is accepted
-- must read NO directories.
local tree, mtimes, dir_reads

local function setTree(files)
    tree = files
    dir_reads = 0
    package.loaded["libs/libkoreader-lfs"].dir = function(path)
        dir_reads = dir_reads + 1
        local names = tree[path] or {}
        local i = 0
        return function() i = i + 1; return names[i] end
    end
    package.loaded["libs/libkoreader-lfs"].attributes = function(fp, key)
        if key == "modification" then return mtimes[fp] or 0 end
        if key == "mode" then return tree[fp] and "directory" or "file" end
        return nil
    end
end

local function freshRepo()
    -- A restart: new module state, same fake disk.
    return dofile("lib/bookshelf_book_repository.lua")
end

local function setup()
    disk.data, disk.saves, disk.loads, disk.deletes = nil, 0, 0, 0
    disk.files = {}
    package.loaded["engines/sui_library_scan"] = nil
    mtimes = { ["/home"] = 10, ["/home/sub"] = 20,
               ["/home/a.epub"] = 100, ["/home/sub/b.epub"] = 200 }
    setTree({
        ["/home"]     = { ".", "..", "a.epub", "sub" },
        ["/home/sub"] = { ".", "..", "b.epub" },
    })
    _G._test_settings = { home_dir = "/home", bookshelf_latest_walk_depth = 3 }
    _G._test_bim_data = {
        ["/home/a.epub"]     = { title = "A" },
        ["/home/sub/b.epub"] = { title = "B" },
    }
end

t.test("a fresh walk writes a snapshot", function()
    setup()
    local Repo = freshRepo()
    assert(#Repo.getLatest(10) == 2, "fixture did not walk")
    assert(disk.saves == 1, "the walk was not persisted, saves=" .. disk.saves)
    assert(dir_reads > 0, "nothing was read; the fixture is not exercising the walk")
end)

t.test("a restart reuses the snapshot instead of walking", function()
    setup()
    freshRepo().getLatest(10)          -- populate
    local before = disk.saves
    dir_reads = 0
    local Repo2 = freshRepo()           -- restart
    local out = Repo2.getLatest(10)
    assert(#out == 2, "the snapshot lost books: got " .. #out)
    -- The saving IS the directories not read. Anything else is decoration.
    assert(dir_reads == 0, "walked anyway, read " .. dir_reads .. " directories")
    assert(disk.saves == before, "an accepted snapshot was rewritten")
end)

t.test("a changed directory makes the restart walk again", function()
    setup()
    freshRepo().getLatest(10)
    -- A new book bumps its directory's mtime. This is the ONLY thing standing
    -- between a stale snapshot and a shelf that cannot see new books.
    tree["/home"] = { ".", "..", "a.epub", "sub", "c.epub" }
    mtimes["/home"] = 11
    mtimes["/home/c.epub"] = 300
    _G._test_bim_data["/home/c.epub"] = { title = "C" }
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a changed library was served from a stale snapshot")
    assert(#out == 3, "the new book never appeared: got " .. #out)
end)

t.test("a deleted book is noticed too", function()
    setup()
    freshRepo().getLatest(10)
    tree["/home/sub"] = { ".", ".." }
    mtimes["/home/sub"] = 21
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a deletion was served from a stale snapshot")
    assert(#out == 1, "the removed book is still listed: got " .. #out)
end)

t.test("a snapshot from a different library is not used", function()
    setup()
    freshRepo().getLatest(10)
    -- home_dir is part of the key. Serving one library's walk for another
    -- would show the wrong books entirely.
    disk.data.key = "/somewhere/else:3"
    dir_reads = 0
    freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot for another home_dir was accepted")
end)

t.test("a snapshot from an older format is not used", function()
    setup()
    freshRepo().getLatest(10)
    disk.data.version = 0
    dir_reads = 0
    freshRepo().getLatest(10)
    assert(dir_reads > 0, "a snapshot with an unknown version was accepted")
end)

t.test("a corrupt snapshot is a miss, not a crash", function()
    setup()
    freshRepo().getLatest(10)
    disk.data.value.list = "not a table"
    dir_reads = 0
    local out = freshRepo().getLatest(10)
    assert(dir_reads > 0, "a malformed snapshot was accepted")
    assert(#out == 2, "a malformed snapshot broke the walk")
end)

t.test("invalidateWalkCache drops the snapshot as well as the memory", function()
    setup()
    local Repo = freshRepo()
    Repo.getLatest(10)
    Repo.invalidateWalkCache()
    -- Anything that says "forget the library" has to reach the copy that
    -- survives a restart, or the next launch resurrects what was invalidated.
    assert(disk.deletes > 0, "the persisted walk survived an invalidation")
    for path in pairs(disk.files) do
        assert(not path:find("/walks/", 1, true), "the snapshot is still on disk")
    end
end)

t.test("five unchanged roots all survive repeated restarts", function()
    setup()
    local roots, fixture = {}, {}
    for i = 1, 5 do
        local root = "/root" .. i
        roots[i] = root
        fixture[root] = { ".", "..", "book.epub" }
        mtimes[root] = 10
    end
    setTree(fixture)
    local scope = { roots = roots }
    assert(#freshRepo().getAllFilepaths(scope) == 5)
    assert(disk.saves == 5)
    for _ = 1, 2 do
        dir_reads = 0
        assert(#freshRepo().getAllFilepaths(scope) == 5)
        assert(dir_reads == 0, "root snapshots overwrote each other")
        assert(disk.saves == 5, "unchanged roots were saved again")
    end
    mtimes[roots[3]] = 11
    dir_reads = 0
    assert(#freshRepo().getAllFilepaths(scope) == 5)
    assert(dir_reads == 1, "only the changed root should be walked")
end)

t.test("old single-root snapshots are still readable", function()
    setup()
    disk.files["/tmp/bookshelf-walk-test/cache/bookshelf/bookshelf.walk"] = {
        version = 1, key = "/home:3",
        list = { { fp = "/home/a.epub", mtime = 100 }, { fp = "/home/sub/b.epub", mtime = 200 } },
        dirs = { ["/home"] = 10, ["/home/sub"] = 20 },
    }
    assert(#freshRepo().getAllFilepaths() == 2)
    assert(dir_reads == 0)
end)

local function scheduler()
    local queue = {}
    package.loaded["ui/uimanager"] = {
        scheduleIn = function(_, _, fn) queue[#queue + 1] = fn end,
        unschedule = function(_, fn)
            for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end
        end,
    }
    return queue, function() assert(table.remove(queue, 1), "no pending tick")() end
end

local function largeTree()
    setup()
    local names = { ".", ".." }
    for i = 1, 500 do names[#names + 1] = i .. ".epub" end
    setTree({ ["/home"] = names })
end

t.test("preload yields, pauses for interaction and publishes only complete roots", function()
    largeTree()
    local queue, tick = scheduler()
    local active = true
    local Repo = freshRepo()
    Repo.prewarmFilepaths({ "/home" }, { is_active = function() return active end })
    assert(dir_reads == 0, "preload ran synchronously")
    tick()
    assert(disk.saves == 0 and #queue == 1, "partial walk was published")
    active = false
    tick()
    assert(disk.saves == 0)
    active = true
    local ticks = 0
    while #queue > 0 do tick(); ticks = ticks + 1; assert(ticks < 50) end
    assert(ticks > 1 and disk.saves == 1)
    dir_reads = 0
    assert(#Repo.getAllFilepaths() == 500 and dir_reads == 0)
end)

t.test("cancelling a yielded preload does not publish it", function()
    largeTree()
    local queue, tick = scheduler()
    local cancel = freshRepo().prewarmFilepaths({ "/home" })
    tick()
    cancel()
    assert(#queue == 0 and disk.saves == 0)
end)

t.test("foreground queries win over an older yielded preload", function()
    largeTree()
    local queue, tick = scheduler()
    local Repo = freshRepo()
    Repo.prewarmFilepaths({ "/home" })
    tick()
    assert(#Repo.getAllFilepaths() == 500)
    while #queue > 0 do tick() end
    assert(disk.saves == 1, "preload replaced the foreground cache")
end)

t.test("invalidation cancels a yielded preload", function()
    largeTree()
    local queue, tick = scheduler()
    local Repo = freshRepo()
    Repo.prewarmFilepaths({ "/home" })
    tick()
    Repo.invalidateWalkCache()
    local before = disk.saves
    while #queue > 0 do tick() end
    assert(disk.saves == before, "invalidated results came back")
end)

t.test("cancelling closes a yielded directory handle and stops future work", function()
    largeTree()
    local lfs = package.loaded["libs/libkoreader-lfs"]
    local original_dir, closed = lfs.dir, 0
    lfs.dir = function(path)
        local iter = original_dir(path)
        local handle = { close = function() closed = closed + 1 end }
        return function()
            local name = iter()
            if not name then handle:close() end
            return name
        end, handle
    end
    local queue, tick = scheduler()
    local alive = true
    freshRepo().prewarmFilepaths({ "/home" }, { is_alive = function() return alive end })
    tick()
    assert(closed == 0, "expected a suspended iterator")
    alive = false
    tick()
    assert(closed == 1 and #queue == 0 and disk.saves == 0)
end)

t.test("foreground replacement during final validation is not overwritten", function()
    setup()
    -- 63 directory entries, then the 64th checkpoint yields in validation.
    local names = { ".", ".." }
    for i = 1, 61 do names[#names + 1] = i .. ".epub" end
    setTree({ ["/home"] = names })
    local queue, tick = scheduler()
    local Repo = freshRepo()
    Repo.prewarmFilepaths({ "/home" })
    tick()
    assert(disk.saves == 0)
    assert(#Repo.getAllFilepaths() == 61 and disk.saves == 1)
    while #queue > 0 do tick() end
    assert(disk.saves == 1, "final validation published over the foreground cache")
end)

t.test("recent input pauses preload until Home becomes idle", function()
    largeTree()
    local queue, tick = scheduler()
    local last_input = math.huge
    local cancel = freshRepo().prewarmFilepaths({ "/home" }, {
        last_input_at = function() return last_input end,
    })
    tick()
    assert(dir_reads == 0 and #queue == 1)
    last_input = 0
    tick()
    assert(dir_reads == 1)
    cancel()
end)

t.test("a matching SimpleUI index avoids another walk and keeps extra formats", function()
    setup()
    package.loaded["engines/sui_library_scan"] = {
        peekFileIndex = function(root, depth)
            assert(root == "/home" and depth == 3)
            return { complete = true, files = {
                { fp = "/home/a.epub", mtime = 100 },
                { fp = "/home/sub/b.fb3", mtime = 200 },
                { fp = "/home/cover.jpg", mtime = 200 },
                { fp = "/home2/not-here.epub", mtime = 200 },
            }, dirs = { ["/home"] = 10, ["/home/sub"] = 20 } }
        end,
    }
    local files = freshRepo().getAllFilepaths()
    assert(#files == 2 and files[2] == "/home/sub/b.fb3")
    assert(dir_reads == 0)
    mtimes["/home"] = 11
    assert(#freshRepo().getAllFilepaths() == 2)
    assert(dir_reads > 0, "stale shared index was trusted")
end)

t.done()
