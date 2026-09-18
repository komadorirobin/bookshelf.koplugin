-- The upstream wallpaper layout must stop above the fork's SimpleUI dock.
package.path = "./?.lua;./?/init.lua;" .. package.path
local H = dofile("tests/_helpers.lua")
local t, eq = H.runner(), H.eq
local file = assert(io.open("lib/bookshelf_widget.lua"))
local src = file:read("*a")
file:close()
local body = assert(src:match("\n(function BookshelfWidget:_footerPanelRectRaw%(.-\nend)\n"))
local env = setmetatable({
    BookshelfWidget = {},
    Size = { radius = { window = 8 } },
    require = function(name)
        assert(name == "lib/bookshelf_cover_progress")
        return { resolvedColors = function() return { panel_bg = "paper" } end }
    end,
}, { __index = _G })
if setfenv then
    local fn = assert(loadstring(body))
    setfenv(fn, env)
    fn()
else
    assert(load(body, "footer", "t", env))()
end

local function widget(dock, footer, hit)
    return setmetatable({
        width = 1264, height = 1680,
        _layoutPrimitives = function() return 32, 1200 end,
        _simpleUIReservedBottom = function() return dock end,
        _paginationFooterHeight = function() return footer end,
        _paginationFooterReserveHeight = function() return footer end,
        _paginationFooterHitExtension = function() return hit end,
    }, { __index = env.BookshelfWidget })
end

t.test("footer shading stays above the SimpleUI dock on a Bigme-sized screen", function()
    local x, y, w, h = widget(120, 72, 12):_footerPanelRectRaw(0.5)
    eq(x, 16); eq(y, 1488); eq(w, 1232); eq(h, 60)
    assert(y + h <= 1680 - 120)
end)

t.test("standalone footer shading follows the user-scaled footer", function()
    local _, y, _, h = widget(0, 100, 20):_footerPanelRectRaw(0.5)
    eq(y, 1580); eq(h, 80)
end)

t.test("a hidden footer or an unshaded background gets no footer panel", function()
    eq(widget(120, 0, 12):_footerPanelRectRaw(0.5), nil)
    eq(widget(120, 72, 12):_footerPanelRectRaw(0), nil)
end)

t.test("empty and populated shelves put the wallpaper behind the content", function()
    for _, names in ipairs{
        { "empty_overlap", "empty_wallpaper", "empty_frame" },
        { "overlap_group", "wallpaper", "main_frame" },
    } do
        local group, paper, frame = names[1], names[2], names[3]
        local bg = assert(src:find(group .. "[#" .. group .. " + 1] = " .. paper, 1, true))
        local fg = assert(src:find(group .. "[#" .. group .. " + 1] = " .. frame, 1, true))
        assert(bg < fg)
    end
    assert(src:find("extra = usable_h - base_sum", 1, true),
        "grid gap balancing must exclude the dock")
    assert(src:find("local layout_slack = usable_h - layout_sum", 1, true),
        "leftover shelf space must exclude the dock")
end)

t.done()
