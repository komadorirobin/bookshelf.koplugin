-- spine_widget.lua
-- One book's cover. Cover render path when book.cover_bb is present;
-- otherwise paper-tone fallback.
--
-- Both render paths produce a "card with shadow" composition: the actual
-- card occupies the bottom-left of the slot, and a darker rounded
-- rectangle is painted at top-right offset behind it, giving the
-- impression of light from below-left. The slot's outer (w × h)
-- footprint is preserved so adjacent shelf cells don't overlap.

local Blitbuffer      = require("ffi/blitbuffer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local ImageWidget     = require("ui/widget/imagewidget")
local Widget          = require("ui/widget/widget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Screen          = require("device").screen

-- Shadow geometry shared by both render paths.
local SHADOW_OFFSET = Screen:scaleBySize(4)        -- shadow offset in dp
local CARD_RADIUS   = Screen:scaleBySize(4)        -- rounded corner radius
local CARD_BORDER   = Screen:scaleBySize(1)        -- 1dp border on the card
local SHADOW_GRAY   = Blitbuffer.gray(0.55)        -- grey level for the shadow

-- A simple Widget subclass that paints a rounded rectangle in a fixed grey.
-- Used as the shadow layer behind every cover. Has its own dimen so
-- OverlapGroup positioning containers can size it correctly.
local ShadowRect = Widget:extend{
    width  = nil,
    height = nil,
}
function ShadowRect:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end
function ShadowRect:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, SHADOW_GRAY, CARD_RADIUS)
end

local SpineWidget = InputContainer:extend{
    book      = nil,
    width     = nil,
    height    = nil,
    on_tap    = nil,
    on_hold   = nil,
}

function SpineWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.book and self.book.has_cover and self.book.cover_bb then
        self[1] = self:_renderCover()
    else
        self[1] = self:_renderFallback()
    end
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

-- Wraps an inner card widget in a "card with shadow" composition. The inner
-- widget is positioned at the bottom-left of the slot; a ShadowRect of the
-- same size is positioned at the top-right, painted behind the card.
function SpineWidget:_renderShadowedCard(inner)
    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET
    local outer  = Geom:new{ w = self.width, h = self.height }
    return OverlapGroup:new{
        dimen = outer,
        TopContainer:new{
            dimen = outer,
            RightContainer:new{
                dimen = outer,
                ShadowRect:new{ width = card_w, height = card_h },
            },
        },
        BottomContainer:new{
            dimen = outer,
            LeftContainer:new{
                dimen = outer,
                inner,
            },
        },
    }, card_w, card_h
end

function SpineWidget:_renderCover()
    local outer, card_w, card_h = self.width, self.width - SHADOW_OFFSET, self.height - SHADOW_OFFSET
    local cover = FrameContainer:new{
        bordersize = CARD_BORDER,
        radius     = CARD_RADIUS,
        padding    = 0,
        ImageWidget:new{
            image  = self.book.cover_bb,
            width  = card_w,
            height = card_h,
            -- scale_factor omitted (= nil) → ImageWidget stretches the image
            -- to fill width × height (CSS object-fit: fill semantics).
        },
    }
    return (self:_renderShadowedCard(cover))
end

function SpineWidget:_renderFallback()
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font          = require("ui/font")

    local card_w   = self.width  - SHADOW_OFFSET
    local card_h   = self.height - SHADOW_OFFSET
    local text_pad = Size.padding.large
    -- The inner-card border eats CARD_BORDER pixels on each side; white bar
    -- width matches the visible interior so it stops at the rounded edge.
    local bar_w    = card_w - CARD_BORDER * 2

    local function whiteBar(text, face, bold)
        local box = TextBoxWidget:new{
            text      = text,
            face      = face,
            width     = bar_w - text_pad * 2,
            alignment = "center",
            bold      = bold,
        }
        return FrameContainer:new{
            bordersize    = 0,
            background    = Blitbuffer.COLOR_WHITE,
            padding       = 0,
            padding_left  = text_pad,
            padding_right = text_pad,
            box,
        }
    end

    local title  = whiteBar(self.book and self.book.title or "?",
                            Font:getFace("infofont", 12), true)
    local author = whiteBar(self.book and self.book.author or "",
                            Font:getFace("infofont", 10), false)

    local stack = VerticalGroup:new{
        align = "center",
        title,
        author,
    }

    -- Paper-tone card: faint grey fill so the fallback reads as a card against
    -- the white page. The inner CenterContainer is sized to (card_w − 2*border,
    -- card_h − 2*border) so the FrameContainer's outer size stays exactly at
    -- card_w × card_h (matches the cover render path).
    local card = FrameContainer:new{
        bordersize = CARD_BORDER,
        radius     = CARD_RADIUS,
        padding    = 0,
        background = Blitbuffer.gray(0.07),
        CenterContainer:new{
            dimen = Geom:new{
                w = card_w - CARD_BORDER * 2,
                h = card_h - CARD_BORDER * 2,
            },
            stack,
        },
    }
    return (self:_renderShadowedCard(card))
end

-- Only consume the gesture when we actually have a callback to invoke.
-- Otherwise let it bubble so an enclosing widget (e.g. HeroCard) can handle it.
function SpineWidget:onTap()
    if not self.on_tap then return false end
    self.on_tap(self.book)
    return true
end
function SpineWidget:onHold()
    if not self.on_hold then return false end
    self.on_hold(self.book)
    return true
end

return SpineWidget
