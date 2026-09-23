-- Labels and pagination may be transparent without clearing the hero/chips.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local function read(path)
    local f = assert(io.open(path))
    local s = f:read("*a")
    f:close()
    return s
end
local function compile(src, env)
    if setfenv then
        local fn = assert(loadstring(src))
        setfenv(fn, env)
        return fn()
    end
    return assert(load(src, "backdrops", "t", env))()
end
local function method(src, class, name)
    return assert(src:match("\n(function " .. class .. ":" .. name .. "%([^\n]*\n.-\nend)\n"), name)
end

package.loaded["logger"] = { dbg = function() end, warn = function() end }
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
local W = require("lib/bookshelf_wallpaper")
local KEY = "wallpaper_transparent_labels_footer"
local TITLE = "Transparent book titles and page indicator"
local stored, generation, writes, repaints, rebuilt = {}, 0, {}, {}, 0
local store = {
    read = function(k, default) if stored[k] ~= nil then return stored[k] end; return default end,
    isTrue = function(k) return stored[k] == true end,
    save = function(k, v)
        stored[k] = v
        writes[#writes + 1] = k
        generation = generation + 1
    end,
    generation = function() return generation end,
    flush = function() end,
}
local Screen = { night_mode = false, scaleBySize = function(_, n) return n end }
local palette = { panel_bg = "paper", ink = "ink" }
local function dependency(name)
    if name == "lib/bookshelf_wallpaper" then return W end
    if name == "lib/bookshelf_cover_progress" then
        return { resolvedColors = function() return palette end }
    end
    error("Unexpected require: " .. name)
end
local common = { BookshelfSettings = store, Screen = Screen, require = dependency }
setmetatable(common, { __index = _G })
local function reset()
    stored = { [W.SCRIM_SETTING] = 0.85, [W.BUTTONS_SETTING] = false }
    generation = generation + 1
    writes, repaints, rebuilt = {}, {}, 0
    Screen.night_mode = false
    W.isShowing = function() return true end
    W.ground = function() return nil end
end

-- Execute the production label wrapper and its painter, not a copy of its rule.
local row = read("lib/bookshelf_shelf_row.lua")
local plate = assert(row:match("(    local PLATE_PAD_X =.-)    local label_gap ="))
local frame = {}
function frame:new(o) return setmetatable(o, { __index = self }) end
function frame:getSize()
    local s = self[1]:getSize()
    return { w = s.w + self.padding_left + self.padding_right,
             h = s.h + self.padding_top + self.padding_bottom }
end
function frame:paintTo(bb, x, y) self[1]:paintTo(bb, x, y) end
local label_env = setmetatable({ FrameContainer = frame }, { __index = common })
local buildPlate = compile("return function()\n" .. plate
    .. "\nreturn plated, plateTextWidth\nend", label_env)
local function paintLabel()
    local ops = {}
    W.scrim = function(_, _, _, _, _, _, strength)
        ops[#ops + 1] = { kind = "background", strength = strength }
    end
    local text = {
        getSize = function() return { w = 100, h = 18 } end,
        paintTo = function() ops[#ops + 1] = { kind = "text" } end,
    }
    local plated, textWidth = buildPlate()
    local widget = plated(text)
    widget:paintTo({}, 10, 200)
    return ops, textWidth(120), widget == text
end

-- Use the real memo and footer geometry at the user's screen dimensions.
local widget_src = read("lib/bookshelf_widget.lua")
local widget_env = setmetatable({
    BookshelfWidget = {}, Size = { radius = { window = 8 }, line = { medium = 2 } },
    Blitbuffer = { gray = function(v) return v end },
}, { __index = common })
local ground = assert(widget_src:match("(local function _groundKey%(.-\nend)\n"))
    .. "\n" .. assert(widget_src:match("(local function _sameColour%(.-\nend)\n"))
for _, name in ipairs{ "_groundState", "_footerPanelRectRaw", "footerPanelRect",
                       "wallpaperScrimStrength", "_topPanelPlan", "_attachTopPanel" } do
    ground = ground .. "\n" .. method(widget_src, "BookshelfWidget", name)
end
compile(ground, widget_env)
local function shelf()
    return setmetatable({
        width = 1264, height = 1680,
        _wallpaperWidget = function() return W.isShowing() and {} or nil end,
        _themeFlipsRaw = function() return false end,
        _pageColourStored = function() return W.ground() ~= nil end,
        _pageGroundColor = function() return "ground" end,
        _scrimStrengthRaw = function() return W.scrimStrength(store.read) end,
        _layoutPrimitives = function() return 32, 1200 end,
        _simpleUIReservedBottom = function() return 120 end,
        _paginationFooterHeight = function() return 72 end,
        _paginationFooterReserveHeight = function() return 72 end,
        _paginationFooterHitExtension = function() return 12 end,
    }, { __index = widget_env.BookshelfWidget })
end

local function capturePanel()
    local panels = {}
    W.scrim = function(_, x, y, w, h, color, strength)
        panels[#panels + 1] = { x = x, y = y, w = w, h = h, color = color, strength = strength }
    end
    W.setPanel = function() end
    return panels
end
local function paintTopPanel(w, list)
    local panels = capturePanel()
    local group = { paintTo = function() end }
    assert(w:_attachTopPanel(group, { PAD = 32, content_w = 1200, band_h = 600, list_full = list }))
    group:paintTo({ paintRect = function() end }, 32, 32)
    return panels[1]
end
local fs_src = read("lib/bookshelf_micro_fullscreen.lua")
local boundary = assert(fs_src:match("(    local fp_x, fp_y.-)    if fp_y then"))
local shared_panel = assert(fs_src:match("(    local panel\n.-)    %-%- A hairline along the top"))
local fs_env = setmetatable({ Widget = frame, Geom = frame }, { __index = common })
local buildFullscreenPanel = compile("return function(self)\n"
    .. "local sw, sh, PAD, top, status_h, grid_top = 1264, 1680, 32, 32, 20, 64\n"
    .. boundary .. shared_panel .. "\nreturn panel\nend", fs_env)

local settings_src = read("lib/bookshelf_settings.lua")
local settings_env = setmetatable({
    Settings = {}, _ = function(s) return s end,
    UIManager = { setDirty = function(_, _, mode) repaints[#repaints + 1] = mode end },
}, { __index = common })
compile(method(settings_src, "Settings", "_wallpaperMenu") .. "\n"
    .. method(settings_src, "Settings", "_markDirty"), settings_env)
local function menu()
    local settings = setmetatable({
        _bw = { _rebuild = function() rebuilt = rebuilt + 1 end },
    }, { __index = settings_env.Settings })
    for _, item in ipairs(settings:_wallpaperMenu()) do
        if item.text == TITLE then return item end
    end
    error("Missing transparency option")
end

t.test("default preserves the title plate, footer panel and upper chrome", function()
    reset()
    local ops, width, bare = paintLabel()
    eq(ops, { { kind = "background", strength = 0.85 }, { kind = "text" } })
    eq(width, 110); eq(bare, false)
    local w = shelf()
    eq(w:wallpaperScrimStrength(), 0.85)
    eq({ w:footerPanelRect() }, { 16, 1488, 1232, 60, 8, 0.85, "paper" })
end)

t.test("the opt-in removes the actual title plate, not the text", function()
    reset()
    store.save(KEY, true)
    local ops, width, bare = paintLabel()
    eq(ops, { { kind = "text" } })
    eq(width, 120); eq(bare, true, "no frame or plate padding remains")
end)

t.test("the opt-in removes only the footer from the shared ground state", function()
    reset()
    local w = shelf()
    assert(w:footerPanelRect())
    store.save(KEY, true)
    eq(w:footerPanelRect(), nil, "setting generation must invalidate the footer memo")
    eq({ w:footerPanelRect(true) }, { 16, 1488, 1232, 0, 8, 0.85, "paper" },
        "shared panels keep the footer boundary, not its fill")
    eq(w:wallpaperScrimStrength(), 0.85, "hero and chip shading must stay on")
    eq(W.transparentButtons(store.read), false, "chip/button backgrounds stay unchanged")
    store.save(KEY, false)
    assert(w:footerPanelRect(), "turning it off restores the footer")
    eq(select(3, paintLabel()), false, "turning it off restores the label plate")
end)

t.test("the actual book information and chip panel paints identically", function()
    reset()
    local w = shelf()
    local before = paintTopPanel(w, false)
    store.save(KEY, true)
    eq(paintTopPanel(w, false), before)
    eq(before, { x = 16, y = 16, w = 1232, h = 632, color = "paper", strength = 0.85 })
end)

t.test("list mode keeps its row panel but stops it before the footer", function()
    reset()
    local w = shelf()
    local before = paintTopPanel(w, true)
    eq(before.y + before.h, 1548)
    store.save(KEY, true)
    local after = paintTopPanel(w, true)
    eq(after.y + after.h, 1488)
    eq(after.strength, 0.85)
    eq(after.y, before.y); eq(after.w, before.w)
    store.save(KEY, false)
    eq(paintTopPanel(w, true), before)
end)

t.test("full-screen modules keep their shared panel above the transparent footer", function()
    reset()
    local w = shelf()
    for _, enabled in ipairs{ false, true, false } do
        store.save(KEY, enabled)
        local panels = capturePanel()
        local panel = assert(buildFullscreenPanel({ bw = w }), "module panel must stay")
        panel:paintTo({})
        eq(#panels, 1)
        eq(panels[1].y + panels[1].h, enabled and 1488 or 1548)
        eq(panels[1].strength, 0.85)
    end
end)

t.test("legacy global transparency is not changed by the new choice", function()
    reset()
    stored[W.SCRIM_SETTING], stored[W.BUTTONS_SETTING] = 0, true
    store.save(KEY, true)
    eq(shelf():wallpaperScrimStrength(), 0)
    eq(shelf():footerPanelRect(), nil)
    eq(paintLabel(), { { kind = "text" } })
    eq(W.transparentButtons(store.read), true)
end)

t.test("the override works over wallpaper, page colour and dark/expanded shelves", function()
    for _, night in ipairs{ false, true } do
        for _, picture in ipairs{ false, true } do
            reset()
            Screen.night_mode = night
            W.isShowing = function() return picture end
            W.ground = function() if not picture then return "ground" end end
            store.save(KEY, true)
            local w = shelf()
            w._expanded = true
            eq(paintLabel(), { { kind = "text" } })
            eq(w:footerPanelRect(), nil)
            eq(w:wallpaperScrimStrength(), 0.85)
        end
    end
end)

t.test("the menu saves only the new choice, rebuilds and fully repaints", function()
    reset()
    local updates = 0
    local touchmenu = { updateItems = function() updates = updates + 1 end }
    local item = menu()
    assert(not item.checked_func())
    item.callback(touchmenu)
    eq(stored[KEY], true)
    eq(writes, { KEY }, "do not silently change the global panel or chip settings")
    eq(menu().checked_func(), true, "a freshly opened menu reads the saved choice")
    eq(rebuilt, 1); eq(repaints, { "full" }); eq(updates, 1)
    item.callback(touchmenu)
    eq(stored[KEY], false)
    eq(rebuilt, 2); eq(repaints, { "full", "full" }); eq(updates, 2)
end)

t.test("ordinary settings still use a partial repaint", function()
    reset()
    settings_env.Settings._bw = { _rebuild = function() rebuilt = rebuilt + 1 end }
    settings_env.Settings:_markDirty()
    eq(rebuilt, 1); eq(repaints, { "ui" })
end)

t.done()
