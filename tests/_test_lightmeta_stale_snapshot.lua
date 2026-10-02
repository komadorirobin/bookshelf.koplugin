-- tests/_test_lightmeta_stale_snapshot.lua
-- The light-meta snapshot is served even when the BIM db has moved on, and a
-- background refresh replaces it -- so the one launch cost we have seen reach
-- 15s (the batch SELECT over a blob-heavy bookinfo table, issue 262) leaves
-- the launch path. Pins: fresh vs stale vs older-format handling, and that the
-- refresh saves fresh rows and drops the derived map, once at a time.
--
-- Bodies are extracted by name; their upvalues become stubbable globals.
-- Run from the plugin root: lua tests/_test_lightmeta_stale_snapshot.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_book_repository.lua"):read("*a")

local function bodyOf(pat, name)
    local body = src:match(pat)
    assert(body, "could not find " .. name)
    return body
end
local function compile(code, env)
    if _G.setfenv then local f = assert(_G.loadstring(code)); _G.setfenv(f, env); return f end
    return assert(load(code, "body", "t", env))
end

local load_body = bodyOf("\nlocal function _loadRowSnapshot%(%)\n(.-)\nend\n", "_loadRowSnapshot")
local sched_body = bodyOf("\nlocal function _scheduleLightMetaRefresh%(%)\n(.-)\nend\n", "_scheduleLightMetaRefresh")

local function loader(stored, live_fp)
    local env = {
        type = type, pcall = pcall, string = string,
        _bimDbFingerprint = function() return live_fp end,
        _lightMetaPersist = function() return { load = function() return stored end } end,
    }
    return compile(load_body, env)
end

t.test("a matching fingerprint is fresh", function()
    local rows = { ["/b/a"] = { title = "A" } }
    local got, fresh = loader({ fingerprint = "v2:100:5", rows = rows }, "v2:100:5")()
    assert(got == rows and fresh == true)
end)

t.test("a moved db fingerprint of the same format is served STALE", function()
    local rows = { ["/b/a"] = { title = "A" } }
    local got, fresh = loader({ fingerprint = "v2:100:5", rows = rows }, "v2:140:9")()
    assert(got == rows, "stale rows must still be handed back")
    assert(fresh == false, "...flagged stale")
end)

t.test("an older snapshot format is never served, stale or not", function()
    -- v1 rows lack pages/description/has_cover: buildBookMeta's fast path
    -- would build records missing fields. nil forces the live batch.
    local got = loader({ fingerprint = "v1:100:5", rows = { x = {} } }, "v2:100:5")()
    assert(got == nil)
end)

t.test("garbage on disk is nil", function()
    assert(loader("not a table", "v2:1:1")() == nil)
    assert(loader({ rows = {} }, "v2:1:1")() == nil, "no fingerprint: nil")
end)

t.test("a write that only reached the -wal file moves the fingerprint", function()
    -- WAL mode leaves the main file untouched until a checkpoint; a
    -- fingerprint of the main file alone called the old snapshot fresh.
    local fp_body = bodyOf("\nlocal function _bimDbFingerprint%(%)\n(.-)\nend\n", "_bimDbFingerprint")
    local files = { ["/s/bookinfo_cache.sqlite3"] = { size = 100, modification = 5 } }
    local lfs = { attributes = function(path, key)
        local a = files[path]; return a and a[key] end }
    local env = {
        pcall = pcall, string = string, type = type, LIGHTMETA_SNAPSHOT_VERSION = 2,
        require = function(name)
            if name == "datastorage" then return { getSettingsDir = function() return "/s" end } end
            return lfs
        end,
    }
    local fingerprint = compile(fp_body, env)
    local no_wal = fingerprint()
    assert(no_wal == "v2:100:5", "no -wal file: the old form, got " .. tostring(no_wal))
    files["/s/bookinfo_cache.sqlite3-wal"] = { size = 4096, modification = 6 }
    local a = fingerprint()
    files["/s/bookinfo_cache.sqlite3-wal"].modification = 9
    local b = fingerprint()
    assert(a ~= no_wal and a ~= b, "a -wal write must change the fingerprint")
    assert(a:match("^v2:"), "same format version, so the old snapshot is served stale, not dropped")
end)

t.test("the cache serves stale rows now and schedules the refresh", function()
    local body = bodyOf("\nlocal function _getLightMetaCache%(home, depth%)\n(.-)\nend\n", "_getLightMetaCache")
    assert(body:match("snapshot, fresh = _loadRowSnapshot%(%)"),
        "the loader's fresh flag must be read")
    assert(body:match("if stale then _scheduleLightMetaRefresh%(%) end"),
        "a stale snapshot must schedule the background refresh")
    assert(body:match("stale%-snapshot"), "the perf line should name the stale source")
end)

t.test("refresh completion saves rows and invalidates derived metadata only", function()
    local requested, saved, invalidated, gate = nil, nil, 0, 0
    local env = {
        pcall = pcall,
        _light_meta_cache = { old = true }, _light_meta_rows_cache = { old = true },
        _lightmeta_refresh = { request = function(opts) requested = opts end },
        _bimDbFingerprint = function() return "v2:100:5" end,
        _saveRowSnapshot = function(rows, fingerprint)
            assert(fingerprint == "v2:100:5"); saved = rows
        end,
        _invalidateCustomMetaGate = function() gate = gate + 1 end,
        Repo = { invalidateBookCache = function(reason)
            assert(reason == "metadata-refresh"); invalidated = invalidated + 1
        end },
    }
    compile(sched_body, env)()
    assert(requested and saved == nil, "requesting refresh must not do I/O")
    requested.done({ ["/b/c"] = { title = "C" } }, requested.fingerprint())
    assert(saved["/b/c"] and invalidated == 1 and gate == 1)
    assert(next(env._light_meta_cache) == nil and env._light_meta_rows_cache == nil)
end)

t.test("a failed snapshot save does not block derived-cache invalidation", function()
    local requested, invalidated = nil, false
    local env = {
        pcall = pcall,
        _lightmeta_refresh = { request = function(opts) requested = opts end },
        _saveRowSnapshot = function() error("disk full") end,
        _invalidateCustomMetaGate = function() end,
        Repo = { invalidateBookCache = function() invalidated = true end },
    }
    compile(sched_body, env)()
    requested.done({ ["/b/c"] = {} }, "v2:100:5")
    assert(invalidated)
end)

t.test("the cache prefers a completed refresh's rows over the disk snapshot", function()
    local body = bodyOf("\nlocal function _getLightMetaCache%(home, depth%)\n(.-)\nend\n", "_getLightMetaCache")
    assert(body:match("if _lightmeta_refresh.rows then"), "the cache must consult the in-memory fresh rows first")
    assert(body:match("if not _lightmeta_refresh.invalidated then"),
        "explicit invalidation must bypass even a matching old snapshot")
end)

t.test("the refresh is declared AFTER the save it calls", function()
    -- The bug that shipped to the rig: _scheduleLightMetaRefresh was inserted
    -- above `local function _saveRowSnapshot`, so inside it the name resolved
    -- to a nil GLOBAL. The save failed silently, the invalidate then dropped
    -- the map, and the stale boot rescheduled itself every two seconds. The
    -- extracted-body tests above cannot see this (they stub the upvalues), so
    -- pin the declaration order in the source itself.
    local save_at    = src:find("\nlocal function _saveRowSnapshot%(rows, fingerprint%)")
    local refresh_at = src:find("\nlocal function _scheduleLightMetaRefresh%(%)")
    local cache_at   = src:find("\nlocal function _getLightMetaCache%(home, depth%)")
    assert(save_at and refresh_at and cache_at, "one of the three functions moved or was renamed")
    assert(save_at < refresh_at, "_saveRowSnapshot must be declared before the refresh that calls it")
    assert(refresh_at < cache_at, "the refresh must be declared before _getLightMetaCache, which calls it")
end)

t.done()
