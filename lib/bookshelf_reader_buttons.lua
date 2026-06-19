--[[
Persistent Bookshelf launcher buttons for the reader view: the start-menu
hamburger and (when micro-modules are enabled) the micro-module grid button.

Registered with ReaderView via view:registerViewModule (the Bookends overlay
mechanism), so paintTo runs as part of every ReaderView paint pass -- drawn INTO
the reader frame, surviving page turns / refreshes. main.lua registers a touch
zone over each button.

Position + glyph design come from lib/bookshelf_footer_geom -- the single source
the home-screen footer buttons also use -- so the launchers are pixel-identical
and track any footer change (the real painted rects are remembered when the
bookshelf is shown; otherwise a computed fallback).
]]
local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local FooterGeom = require("lib/bookshelf_footer_geom")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local Screen     = Device.screen

local ReaderButtons = Widget:extend{
    side           = "left",  -- hamburger side (start_menu_position)
    grid_side      = "right", -- grid side (opposite the hamburger)
    show_hamburger = true,    -- draw the start-menu hamburger (off when start menu = off)
    show_grid      = false,   -- draw the micro-module grid button (fullscreen placement only)
}

function ReaderButtons:paintTo(_bb, _x, _y)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Hamburger (start menu), unless the start menu is set to "off".
    if self.show_hamburger then
        local cx, top = FooterGeom.launcherBarsAnchor(sw, sh, self.side)
        local m = FooterGeom.barMetrics()
        local left = cx - math.floor(m.bar_w / 2)
        for i = 0, 2 do
            _bb:paintRect(left, top + i * (m.bar_t + m.gap), m.bar_w, m.bar_t,
                Blitbuffer.COLOR_BLACK)
        end
    end
    -- Grid (micro-modules), opposite corner, when enabled.
    if self.show_grid then
        local gx, goy = FooterGeom.launcherGridAnchor(sw, sh, self.grid_side)
        FooterGeom.paintGrid(_bb, gx, goy)
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
end

-- Comfortable tap box around the hamburger bars (NOT the full footer-button
-- width, which would swallow the corner's page-turn taps).
function ReaderButtons.tapRect(side)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local cx, top = FooterGeom.launcherBarsAnchor(sw, sh, side)
    local m = FooterGeom.barMetrics()
    local pad = Screen:scaleBySize(10)
    return Geom:new{ x = math.max(0, cx - math.floor(m.bar_w / 2) - pad),
                     y = math.max(0, top - pad),
                     w = m.bar_w + 2 * pad, h = m.span + 2 * pad }
end

-- Comfortable tap box around the grid glyph.
function ReaderButtons.gridTapRect(grid_side)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local gx, goy = FooterGeom.launcherGridAnchor(sw, sh, grid_side)
    local g = FooterGeom.gridMetrics()
    local pad = Screen:scaleBySize(10)
    return Geom:new{ x = math.max(0, gx - pad), y = math.max(0, goy - pad),
                     w = g.W + 2 * pad, h = g.H + 2 * pad }
end

return ReaderButtons
