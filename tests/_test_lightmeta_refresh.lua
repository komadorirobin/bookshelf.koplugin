package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local queue, opened, closed, selects, published, warnings, version, fingerprint
local total, fail_query, on_done
local function reset()
    queue, opened, closed, selects, published, warnings = {}, 0, 0, 0, 0, 0
    total, version, fingerprint, fail_query = 19, 1, "db-1", false
    on_done = function() end
end
local ui = {
    scheduleIn = function(_, delay, fn) queue[#queue + 1] = { delay, fn } end,
    unschedule = function(_, fn)
        for i = #queue, 1, -1 do if queue[i][2] == fn then table.remove(queue, i) end end
    end,
}
package.loaded["ui/uimanager"] = ui
package.loaded.datastorage = { getSettingsDir = function() return "/settings" end }
package.loaded.logger = { warn = function() warnings = warnings + 1 end }
package.loaded["lua-ljsqlite3/init"] = { open = function(path, mode)
    assert(path == "/settings/bookinfo_cache.sqlite3" and mode == "ro")
    opened = opened + 1
    return {
        exec = function(_, sql)
            if sql == "PRAGMA busy_timeout=0;" then return {} end
            if sql == "PRAGMA data_version;" then return { { version } } end
            selects = selects + 1
            if fail_query then error("database is locked") end
            assert(not sql:find("cover_bb", 1, true), "never read cover blobs")
            local last, limit = sql:match("WHERE rowid > (%d+) ORDER BY rowid LIMIT (%d+);")
            last, limit = assert(tonumber(last)), assert(tonumber(limit))
            assert(limit <= 8, "each tick must have bounded SQL work")
            local rows = {}
            for c = 1, 17 do rows[c] = {} end
            for id = last + 1, math.min(total, last + limit) do
                local i = #rows[1] + 1
                rows[1][i], rows[2][i] = id, id == 2 and 1 or 0
                rows[3][i], rows[4][i] = "/books/", id .. ".epub"
                rows[5][i], rows[6][i] = "Title " .. id, "Author"
                rows[7][i], rows[8][i] = "Series", tostring(id)
                rows[11][i], rows[12][i] = "120", "Description"
                rows[13][i], rows[14][i] = 1, 1
            end
            return rows
        end,
        close = function() closed = closed + 1 end,
    }
end }
local function tick()
    local scheduled = assert(table.remove(queue, 1), "no scheduled task")
    scheduled[2]()
end
local function drain()
    local count = 0
    while #queue > 0 do
        tick(); count = count + 1
        assert(count < 100, "runaway refresh loop")
    end
end
local function request(refresh)
    refresh.request{
        fingerprint = function() return fingerprint end,
        done = function(rows, fp)
            published = published + 1
            assert(fp == fingerprint)
            on_done(rows)
        end,
    }
end
local function fresh()
    reset()
    return dofile("lib/bookshelf_lightmeta_refresh.lua")
end

t.test("hidden shelf does no work; visible refresh publishes complete batches only", function()
    local r = fresh()
    request(r)
    assert(#queue == 0 and opened == 0)
    r.setActive(true)
    request(r)
    assert(#queue == 1 and queue[1][1] == 2 and opened == 0)
    tick()
    assert(selects == 1 and not r.rows and published == 0)
    tick()
    assert(selects == 2 and not r.rows)
    tick()
    assert(selects == 3 and published == 1 and closed == 1 and #queue == 0)
    assert(r.rows["/books/19.epub"].pages == 120)
    assert(r.rows["/books/19.epub"].series_index == 19)
    assert(r.rows["/books/19.epub"].description == "Description")
    assert(not r.rows["/books/2.epub"], "in-progress BIM rows must be excluded")
    request(r)
    assert(#queue == 0, "fresh in-memory rows satisfy further requests")
end)
t.test("suspend closes the handle, ignores stale callbacks, and resume restarts", function()
    local r = fresh()
    r.setActive(true); request(r); tick()
    local late = queue[1][2]
    r.setActive(false)
    assert(closed == 1 and #queue == 0 and published == 0)
    late()
    assert(selects == 1 and published == 0)
    r.setActive(true)
    drain()
    assert(opened == 2 and closed == 2 and published == 1)
end)
t.test("explicit invalidation cancels jobs and discards completed raw rows", function()
    local r = fresh()
    r.setActive(true); request(r); tick()
    local late = queue[1][2]
    r.invalidate(); late()
    assert(closed == 1 and not r.rows and r.invalidated and #queue == 0)
    request(r); drain()
    assert(r.rows and not r.invalidated)
    r.invalidate()
    assert(not r.rows and r.invalidated)
end)
for _, change in ipairs({ "version", "fingerprint" }) do
    t.test("a changed " .. change .. " rejects the mixed snapshot without spinning", function()
        local r = fresh()
        r.setActive(true); request(r); tick()
        if change == "version" then version = 2 else fingerprint = "db-2" end
        drain()
        assert(not r.rows and published == 0 and closed == 1 and warnings == 1)
        r.setActive(true)
        assert(#queue == 0, "retry only on a new request")
        request(r); drain()
        assert(r.rows and published == 1)
    end)
end
t.test("busy/error paths release handles and can retry a later request", function()
    local r = fresh()
    fail_query = true
    r.setActive(true); request(r); drain()
    assert(closed == 1 and published == 0 and warnings == 1)
    fail_query = false
    request(r); drain()
    assert(closed == 2 and published == 1)
end)
t.test("completion callback failure cannot trigger repeated database scans", function()
    local r = fresh()
    on_done = function() error("snapshot save failed") end
    r.setActive(true); request(r); drain()
    assert(r.rows and closed == 1)
    request(r)
    assert(#queue == 0)
end)
t.test("an empty BIM database is a valid cached result", function()
    local r = fresh()
    total = 0
    r.setActive(true); request(r); drain()
    assert(r.rows and next(r.rows) == nil and published == 1 and selects == 1)
end)
t.test("without an event loop no database work starts", function()
    local r = fresh()
    package.loaded["ui/uimanager"] = {}
    r.setActive(true); request(r)
    assert(opened == 0 and #queue == 0)
    package.loaded["ui/uimanager"] = ui
end)
local source_file = assert(io.open("lib/bookshelf_widget.lua"))
local widget_source = source_file:read("*a")
source_file:close()
local function widgetMethods()
    local state, methods = {}, {}
    local env = {
        BookshelfWidget = methods, os = os,
        Repo = { setMetadataRefreshActive = function(active) state.metadata = active end },
        package = { loaded = { ["lib/bookshelf_cover_disk_cache"] = {
            setActive = function(active) state.covers = active end,
        } } },
        UIManager = {
            unschedule = function() end, scheduleIn = function() end,
            getTopmostVisibleWidget = function() return state.topmost end,
        },
    }
    for _, name in ipairs({ "_startStatusTimer", "_stopStatusTimer", "onSuspend", "onResume" }) do
        local body = assert(widget_source:match("\n(function BookshelfWidget:" .. name .. "%(.-\nend)\n"))
        local fn
        if setfenv then fn = assert(loadstring(body)); setfenv(fn, env)
        else fn = assert(load(body, name, "t", env)) end
        fn()
    end
    methods._startFilePoll = function() end
    methods._cancelFilePoll = function() end
    methods._cancelPreload = function() end
    methods._cancelChipPreload = function() end
    methods._flushNavStateNow = function() end
    return methods, state
end
t.test("widget suspend/resume pauses both maintenance jobs", function()
    local w, state = widgetMethods()
    w:_startStatusTimer()
    assert(state.metadata and state.covers)
    w:onSuspend()
    assert(not state.metadata and not state.covers)
    state.topmost = w
    w:onResume()
    assert(state.metadata and state.covers)
    w:_stopStatusTimer()
    assert(not state.metadata and not state.covers)
end)
t.test("a covered shelf cannot restart maintenance when the reader resumes", function()
    local w, state = widgetMethods()
    state.topmost = {}
    w:onResume()
    assert(not state.metadata and not state.covers)
    w:_startStatusTimer() -- the ordinary hot-return path, timer already armed
    assert(state.metadata and state.covers)
end)
t.done()
