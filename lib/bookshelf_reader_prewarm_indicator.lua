-- Small static reader overlay shown while Bookshelf is being pre-warmed under
-- the open book. Registered as a ReaderView module, so it paints into the page
-- rather than opening a modal window above the reader.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")

local Screen = Device.screen

local Indicator = Widget:extend{}

function Indicator:paintTo(bb, _x, _y)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local s = Screen:scaleBySize(26)
    local m = Screen:scaleBySize(12)
    local x = m
    local y = sh - s - m
    local t = math.max(1, Screen:scaleBySize(2))
    local pad = math.max(2, Screen:scaleBySize(4))

    -- White badge with a tiny bookshelf glyph: quiet, static, and visible on
    -- both monochrome and colour e-ink without relying on icon fonts.
    bb:paintRect(x, y, s, s, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y, s, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y + s - t, s, t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x, y, t, s, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + s - t, y, t, s, Blitbuffer.COLOR_BLACK)

    local shelf_x = x + pad
    local shelf_w = s - 2 * pad
    local top = y + pad + t
    local gap = math.floor((s - 2 * pad - t) / 3)
    for i = 0, 2 do
        local yy = top + i * gap
        bb:paintRect(shelf_x, yy, shelf_w, t, Blitbuffer.COLOR_BLACK)
    end
    bb:paintRect(shelf_x + math.floor(shelf_w * 0.33), top, t, gap * 2 + t, Blitbuffer.COLOR_BLACK)
    bb:paintRect(shelf_x + math.floor(shelf_w * 0.66), top, t, gap * 2 + t, Blitbuffer.COLOR_BLACK)

    self.dimen = Geom:new{ x = x, y = y, w = s, h = s }
end

return Indicator
