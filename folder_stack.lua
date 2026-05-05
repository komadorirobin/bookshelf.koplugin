-- folder_stack.lua
-- Renders a folder-as-magazine-file: the first book inside the folder peeks
-- out the top, and a manilla cardboard "magazine file" shape wraps the lower
-- half with the folder name printed on its front face.
--
-- Visual composition (back-to-front):
--   1. First-book cover (rendered via SpineWidget at full slot height)
--   2. Magazine front: a filled grey quadrilateral with a sloped top edge.
--      The slope goes from a low point on the LEFT to a high point on the
--      RIGHT (matching the reference image — front wall short, back wall
--      tall). Above the slope the book cover shows; below, cardboard fill.
--   3. Folder name centred on the cardboard's lower portion.
--
-- All shapes paint into an OverlapGroup at slot dimen so the whole stack
-- has the same getSize() / tap zone as a regular SpineWidget — drop-in
-- replacement at the ShelfRow slot level.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- Slope geometry as fractions of slot height. Slope rises to the RIGHT
-- (front wall on left is shorter, back wall on right is taller — matches
-- the reference photo's open-mouth orientation).
local SLOPE_LEFT_FRAC  = 0.55   -- y at left edge (lower point of slope)
local SLOPE_RIGHT_FRAC = 0.40   -- y at right edge (higher point)

-- Cardboard colour — medium-warm grey. Outline a touch darker so the
-- magazine reads as a distinct shape against the cover behind it.
local CARDBOARD       = Blitbuffer.gray(0.25)
local CARDBOARD_EDGE  = Blitbuffer.gray(0.55)

-- MagazineFront: a custom Widget that paints the cardboard polygon. The
-- shape is the slot rectangle minus the upper-left triangle above the
-- slope (which stays empty so the book cover behind shows through).
local MagazineFront = Widget:extend{
    width   = nil,
    height  = nil,
    y_left  = nil,   -- slope y at x = 0
    y_right = nil,   -- slope y at x = width-1
}

function MagazineFront:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MagazineFront:paintTo(bb, x, y)
    local w  = self.width
    local h  = self.height
    local yl = self.y_left
    local yr = self.y_right
    -- Per-row fill. For each scanline dy, compute the slope's x at this
    -- y by inverting slope_y(x) = yl + (yr - yl) * x / (w - 1):
    --   slope_x(y) = (w - 1) * (y - yl) / (yr - yl)
    -- Painted region at row dy is x in [slope_x(dy), w - 1] when
    -- dy is between min(yl, yr) and max(yl, yr); for dy ≥ max the whole
    -- row is painted; for dy < min nothing paints.
    local y_min = math.min(yl, yr)
    local y_max = math.max(yl, yr)
    for dy = 0, h - 1 do
        local x_start
        if dy >= y_max then
            x_start = 0
        elseif dy < y_min then
            x_start = nil   -- entirely above slope; skip
        else
            -- Linear interpolation along the slope. yr < yl in our
            -- orientation (slope rises to the right) so the divisor is
            -- negative; the math still works out.
            local frac = (dy - yl) / (yr - yl)
            x_start = math.floor((w - 1) * frac + 0.5)
            if x_start < 0 then x_start = 0 end
            if x_start > w - 1 then x_start = w - 1 end
        end
        if x_start then
            bb:paintRect(x + x_start, y + dy, w - x_start, 1, CARDBOARD)
        end
    end
    -- Outline edges for definition.
    local b = Size.border.thin
    -- Bottom edge
    bb:paintRect(x, y + h - b, w, b, CARDBOARD_EDGE)
    -- Right edge from y_min downward (back wall)
    bb:paintRect(x + w - b, y + y_min, b, h - y_min, CARDBOARD_EDGE)
    -- Left edge from y_left downward (front wall)
    bb:paintRect(x, y + yl, b, h - yl, CARDBOARD_EDGE)
    -- Slope edge: paint b×b blocks at each step along the slope line.
    local steps = math.max(w, math.abs(yr - yl))
    for s = 0, steps do
        local px = math.floor(s * (w - 1) / steps + 0.5)
        local py = math.floor(yl + (yr - yl) * s / steps + 0.5)
        bb:paintRect(x + px, y + py, b, b, CARDBOARD_EDGE)
    end
end

local FolderStack = InputContainer:extend{
    folder  = nil,    -- { path, label, first_book }
    width   = nil,
    height  = nil,
    on_tap  = nil,    -- function(folder) — drill in
    on_hold = nil,
    is_selected = false,    -- highlight when previewed (matches SpineWidget)
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local h = self.height
    local w = self.width

    -- Layer 1 (back): the first book's cover, full slot height. SpineWidget
    -- handles cover-vs-fallback rendering; we just give it the slot dims.
    -- When the folder is empty (no first_book), SpineWidget's fallback path
    -- paints a paper-tone card with the folder name.
    local book_layer
    if self.folder and self.folder.first_book then
        book_layer = SpineWidget:new{
            book        = self.folder.first_book,
            width       = w,
            height      = h,
            cover_fill  = true,
            is_selected = self.is_selected,
        }
    else
        -- No book in folder: a SpineWidget with no book yields the
        -- paper-tone fallback, but its title would be "?" — feed it a
        -- synthetic Book with the folder name as title so the empty
        -- state still labels correctly above the magazine.
        book_layer = SpineWidget:new{
            book        = { title = self.folder and self.folder.label or "" },
            width       = w,
            height      = h,
            is_selected = self.is_selected,
        }
    end

    -- Layer 2 (front): magazine cardboard with sloped top.
    local y_left  = math.floor(h * SLOPE_LEFT_FRAC)
    local y_right = math.floor(h * SLOPE_RIGHT_FRAC)
    local magazine = MagazineFront:new{
        width   = w,
        height  = h,
        y_left  = y_left,
        y_right = y_right,
    }

    -- Layer 3 (top): folder name centred on the cardboard, between the
    -- slope's lowest point and the bottom of the slot. TextBoxWidget
    -- with width = inner cardboard area lets long names wrap to 2 lines
    -- before the height_overflow_show_ellipsis kicks in.
    local label_top    = math.max(y_left, y_right) + Size.padding.small
    local label_h      = h - label_top - Size.padding.default
    local label_text   = self.folder and self.folder.label or ""
    local label_width  = w - Size.padding.default * 2
    local label_widget = TextBoxWidget:new{
        text                          = label_text,
        face                          = Font:getFace("infofont", 12),
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        width                         = label_width,
        height                        = math.max(label_h, Screen:scaleBySize(20)),
        height_overflow_show_ellipsis = true,
        alignment                     = "center",
    }
    local label_container = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = label_top,
        padding_left  = Size.padding.default,
        padding_right = Size.padding.default,
        label_widget,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        book_layer,
        magazine,
        label_container,
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
