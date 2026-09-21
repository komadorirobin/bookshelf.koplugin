-- Exercise both the upstream warm show and the fork's SimpleUI return route.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t = H.runner()
local src = io.open("main.lua"):read("*a")

local function run(method, opts)
    opts = opts or {}
    local state = { rotations = 0, rebuilds = 0, refreshes = 0, dirty = 0, timers = 0 }
    local screen = { rotation = opts.rotation or 1 }
    function screen:getWidth() return self.rotation % 2 == 0 and 1264 or 1680 end
    function screen:getHeight() return self.rotation % 2 == 0 and 1680 or 1264 end
    function screen:setRotationMode(mode)
        state.rotations = state.rotations + 1
        self.rotation = mode
    end
    local widget = {
        width = 1264, height = 1680, dimen = { w = 1264, h = 1680 },
        profile = { key = "prose" }, _pre_read_rotation = 0,
    }
    function widget:_rebuild()
        state.rebuilds = state.rebuilds + 1
        self.width, self.height = screen:getWidth(), screen:getHeight()
        self.dimen.w, self.dimen.h = self.width, self.height
    end
    function widget:softRefresh() state.refreshes = state.refreshes + 1 end
    widget.refreshAfterReaderReturn = widget.softRefresh
    function widget:_startStatusTimer() state.timers = state.timers + 1 end
    function widget:showFileLocation(fp)
        state.file = fp
        self:_rebuild()
    end
    function widget:setProfile(key)
        self.profile = { key = key }
        self:_rebuild()
    end
    local env = {
        _live_widget = widget,
        _isWidgetTopmost = function() return true end,
        _gettime = function() return 1 end,
        string = string,
        logger = { dbg = function(line) state.log = line end },
        G_reader_settings = { isTrue = function(_self, key)
            return key == "lock_rotation" and opts.locked ~= false
        end },
        UIManager = {
            isWidgetShown = function(_self, w) return w == widget end,
            setDirty = function() state.dirty = state.dirty + 1 end,
        },
        require = function(name)
            if name == "device" then return { screen = screen } end
            if name == "lib/bookshelf_settings" then return {} end
            if name == "lib/bookshelf_reader_park" then
                return { isParked = function() return opts.parked or false end }
            end
            error("unexpected require: " .. name)
        end,
    }
    local body = assert(src:match("\nfunction Bookshelf:" .. method .. "%b()\n(.-)\nend\n"))
    local code = "return function(self, profile_key, target_file)\n" .. body .. "\nend"
    local chunk
    if setfenv then
        chunk = assert(loadstring(code, method))
        setfenv(chunk, env)
    else
        chunk = assert(load(code, method, "t", env))
    end
    local self = {
        _widget = widget,
        _evictHomescreenOverlay = function() state.evicted = true end,
    }
    chunk()(self, opts.profile_key, opts.target_file)
    return state, widget, screen
end

for _, method in ipairs({ "show", "_showAfterReaderReturn" }) do
    t.test(method .. ": keep rotation rebuilds the changed geometry without a Lua error", function()
        local state, widget, screen = run(method)
        H.eq(state.rotations, 0)
        H.eq(screen.rotation, 1)
        H.eq(widget._pre_read_rotation, nil)
        H.eq(state.rebuilds, 1)
        H.eq(state.refreshes, 0)
        H.eq(state.dirty, 1)
        H.eq(widget.width, 1680)
        H.eq(widget.height, 1264)
        H.eq(state.evicted, true)
        if method == "show" then assert(state.log:find("warm-reshape", 1, true)) end
    end)

    t.test(method .. ": unlocked rotation restores the shelf without a rebuild", function()
        local state, widget, screen = run(method, { locked = false })
        H.eq(state.rotations, 1)
        H.eq(screen.rotation, 0)
        H.eq(widget._pre_read_rotation, nil)
        H.eq(state.rebuilds, 0)
        H.eq(state.refreshes, 1)
    end)

    t.test(method .. ": unchanged geometry retains the cheap refresh", function()
        local state = run(method, { rotation = 0 })
        H.eq(state.rotations, 0)
        H.eq(state.rebuilds, 0)
        H.eq(state.refreshes, 1)
    end)

    t.test(method .. ": a parked reader keeps its rotation and saved restore", function()
        local state, widget, screen = run(method, { locked = false, parked = true })
        H.eq(state.rotations, 0)
        H.eq(screen.rotation, 1)
        H.eq(widget._pre_read_rotation, 0)
        H.eq(state.rebuilds, 1)
    end)
end

t.test("SimpleUI file-location return rebuilds only once and preserves the target", function()
    local state, widget = run("_showAfterReaderReturn", { target_file = "/manga/volume2.cbz" })
    H.eq(state.rotations, 0)
    H.eq(state.file, "/manga/volume2.cbz")
    H.eq(state.rebuilds, 1)
    H.eq(state.refreshes, 0)
    H.eq(state.timers, 1)
    H.eq(widget.width, 1680)
end)

t.test("SimpleUI profile return rebuilds only once and preserves the target profile", function()
    local state, widget = run("_showAfterReaderReturn", { profile_key = "comics" })
    H.eq(state.rotations, 0)
    H.eq(widget.profile.key, "comics")
    H.eq(state.rebuilds, 1)
    H.eq(state.refreshes, 0)
    H.eq(state.timers, 1)
    H.eq(widget.width, 1680)
end)

t.done()
