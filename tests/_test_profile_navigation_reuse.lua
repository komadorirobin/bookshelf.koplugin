-- Real navigation methods, without requiring native KOReader widgets.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local fh = assert(io.open("lib/bookshelf_widget.lua"))
local src = fh:read("*a"); fh:close()
local Widget, profiles = {}, { prose = { key = "prose" }, comics = { key = "comics" } }
local location, rows, queries, builds, refreshes, closes, ticks, dispatches, parked, pending
local priority = { { key = "series_index" } }
local fm = { _simpleui_plugin = {} }
local env = setmetatable({
    BookshelfWidget = Widget,
    Screen = { getWidth = function() return 1264 end, getHeight = function() return 1680 end },
    Profiles = {
        get = function(key) return profiles[key] end,
        defaultChip = function(profile) return profile.key == "comics" and "manga" or "fiction" end,
        locationForFile = function() return location end,
        folderSortPriority = function() return priority end,
    },
    BookshelfSettings = { read = function() end, saveDeferred = function() end },
    FolderLabel = { display = function(s) return s end },
    _normFolderPath = function(s) return s end,
    Repo = { getAll = function(path, limit, offset, sort, filter, opts)
        assert(path == location.folder and limit == nil and offset == 0)
        assert(sort == priority and filter == nil and opts.light_only and opts.lazy_cover)
        queries = queries + 1; return rows
    end },
    UIManager = { setDirty = function() end,
        close = function() closes = closes + 1 end,
        nextTick = function(_, fn) ticks[#ticks + 1] = fn end },
    logger = { warn = function() end },
    require = function(name)
        if name == "sui_bookshelf_bridge" then return {
            profileForNavigation = function(action)
                if action == "comics" or action == "prose" then return action end
            end,
        } end
        if name == "lib/bookshelf_reader_park" then return {
            finishForShelfNavigation = function(_, cb, keep)
                if parked then assert(keep); pending = cb; return true end
                return false
            end,
        } end
        if name == "apps/filemanager/filemanager" then return { instance = fm } end
        error("unexpected require " .. name)
    end,
}, { __index = _G })
local function compile(code)
    if setfenv then local f = assert(loadstring(code)); setfenv(f, env); return f end
    return assert(load(code, "navigation", "t", env))
end
for _, name in ipairs{ "setProfile", "showFileLocation", "_dispatchSimpleUIBarAction" } do
    local method = assert(src:match("(function BookshelfWidget:" .. name .. "%b().-\nend)"))
    compile(method)()
end
local init_tail = assert(src:match("(    if self%._initial_target_file then.-self:_startStatusTimer%(%))"))
local finishInit = compile("return function(self)\n" .. init_tail .. "\nend")()
local function widget()
    rows, queries, builds, refreshes, closes, ticks, dispatches, parked, pending = {}, 0, 0, 0, 0, {}, 0, false, nil
    location = { profile_key = "comics", chip_key = "manga", root = "/manga", folder = "/manga/Series", filepath = "/manga/Series/12.epub" }
    for i = 1, 12 do rows[i] = { filepath = "/manga/Series/" .. i .. ".epub" } end
    fm._simpleui_plugin._onTabTap = function() dispatches = dispatches + 1 end
    local obj = setmetatable({
        profile = profiles.prose, chip = "fiction", _cursor = 1, _drilldown_path = {},
        width = 1264, height = 1680,
        _simpleui_bar_ctx = { fm = fm, plugin = fm._simpleui_plugin },
        _rebuild = function() builds = builds + 1 end,
        refreshAfterReaderReturn = function() refreshes = refreshes + 1 end,
        _profileChip = function() return { path = "/prose" } end,
        _profileSettingKey = function() return "chip" end,
        _viewSize = function() return 10 end,
        _clearDpadFocus = function() end, _startStatusTimer = function() end,
        _isSimpleUIInPlaceAction = function(_, action) return action == "power" end,
        setSimpleUIBarHost = function(self, host) self.host = host end,
    }, { __index = Widget })
    Widget.live = obj
    return obj
end

t.test("a cold target resolves its final folder and page before one build", function()
    local obj = widget()
    obj._pending_restore_drill = { { kind = "folder", payload = { path = "/old" } } }
    obj._initial_target_file = location.filepath
    finishInit(obj)
    assert(builds == 1 and queries == 1 and obj._initial_target_found)
    assert(obj.profile == profiles.comics and obj._cursor == 11 and obj.page == 2)
    assert(obj._drilldown_path[1].payload.path == location.folder)
    assert(obj._pending_restore_drill == nil)
end)

t.test("warm target changes rebuild once and identical returns only refresh", function()
    local obj = widget()
    assert(obj:showFileLocation(location.filepath))
    assert(builds == 1 and queries == 1)
    assert(obj:showFileLocation(location.filepath))
    assert(builds == 1 and refreshes == 1 and queries == 2)
    obj.width = 1680
    obj:showFileLocation(location.filepath)
    assert(builds == 2, "rotation requires remeasurement")
end)

t.test("new navigation chrome is not skipped for a longer folder breadcrumb", function()
    local obj = widget()
    obj:showFileLocation(location.filepath)
    table.insert(obj._drilldown_path, 1, { kind = "folder", payload = { path = "/manga" } })
    obj:showFileLocation(location.filepath)
    assert(builds == 2 and refreshes == 0)
end)

t.test("missing targets are reported without a hydration query or double build", function()
    local obj = widget()
    rows = {}
    assert(not obj:showFileLocation(location.filepath))
    assert(builds == 1 and queries == 1 and obj._cursor == 1)
end)

t.test("dock profile switches reuse the widget, and same-profile taps only refresh", function()
    local obj = widget()
    assert(obj:_dispatchSimpleUIBarAction("comics"))
    assert(builds == 1 and closes == 0 and dispatches == 0 and #ticks == 0)
    obj:_dispatchSimpleUIBarAction("comics")
    assert(builds == 1 and refreshes == 1 and Widget.live == obj)
end)

t.test("switches clear profile-local caches, jobs and selection, not the widget", function()
    local obj = widget()
    local selection = dofile("lib/bookshelf_selection.lua").new()
    selection:enterMode(); selection:add("/prose/selected.epub")
    obj._selection = selection
    obj._spine_fetch_cache = { key = "authors", items = { "wrong profile" } }
    obj._warmed_chip_keys = { authors = true }
    obj._preview_book, obj._tap_selected_fp = {}, "/prose/selected.epub"
    local cancelled = false
    obj._cancelChipPreload = function() cancelled = true end
    obj:_dispatchSimpleUIBarAction("comics")
    assert(cancelled and not obj._spine_fetch_cache and not obj._warmed_chip_keys)
    assert(not selection:isActive() and selection:count() == 0)
    assert(not obj._preview_book and not obj._tap_selected_fp)
    assert(Widget.live == obj and builds == 1 and closes == 0)
end)

t.test("parked profile switches wait for the real close, then bind the live host", function()
    local obj = widget()
    parked = true
    obj:_dispatchSimpleUIBarAction("comics")
    assert(builds == 0 and closes == 0 and pending)
    local new_fm = { _simpleui_plugin = {} }
    pending(new_fm)
    assert(builds == 1 and closes == 0 and obj.host.fm == new_fm)
end)

t.test("a stale pending profile switch cannot resurrect a closed widget", function()
    local obj = widget()
    parked = true
    obj:_dispatchSimpleUIBarAction("comics")
    Widget.live = nil
    pending(fm)
    assert(builds == 0 and closes == 0)
end)

t.test("non-profile navigation and in-place actions preserve their normal dispatch", function()
    local obj = widget()
    obj:_dispatchSimpleUIBarAction("power")
    assert(dispatches == 1 and closes == 0)
    obj:_dispatchSimpleUIBarAction("home")
    assert(closes == 1 and #ticks == 1 and dispatches == 1)
    ticks[1]()
    assert(dispatches == 2)
end)

t.done()
