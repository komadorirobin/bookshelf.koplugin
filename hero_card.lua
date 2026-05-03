-- hero_card.lua
-- Currently-reading detail card: cover thumbnail + title + author + token strip + progress bar.

local FrameContainer  = require("ui/widget/container/framecontainer")
local InputContainer  = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TopContainer    = require("ui/widget/container/topcontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup   = require("ui/widget/verticalgroup")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local ProgressWidget  = require("ui/widget/progresswidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local SpineWidget     = require("spine_widget")
local Tokens          = require("tokens")

local HeroCard = InputContainer:extend{
    book        = nil,
    width       = nil,
    height      = nil,
    cover_w     = 116,
    cover_h     = nil,
    lines       = nil,   -- list of token-format strings
    device_state= nil,   -- { now, batt, charging, wifi, light, warmth, mem, ram_mib, disk_free }
    on_tap      = nil,   -- function(book)
    on_hold     = nil,
}

function HeroCard:init()
    self.cover_h = self.cover_h or self.height
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if not self.book then
        self[1] = self:_renderEmpty()
    else
        self[1] = self:_renderFull()
    end
    -- Corrected positional GestureRange form (keyed form is broken — see fd43c4d).
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function HeroCard:_renderEmpty()
    return FrameContainer:new{
        width      = self.width,
        height     = self.height,
        bordersize = Size.border.thin,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = self.height },
            TextBoxWidget:new{
                text  = "Welcome to Bookshelf · Tap a cover to start reading",
                face  = Font:getFace("infofont", 14),
                width = self.width - Size.padding.large * 2,
                alignment = "center",
            },
        },
    }
end

function HeroCard:_renderFull()
    local cover_h = self.cover_h or self.height
    -- Pass tap/hold callbacks through so the cover area itself opens the book
    -- (otherwise SpineWidget consumes the tap with `return true` even when
    -- its own on_tap is nil, and the HeroCard's outer handler never fires).
    local cover = SpineWidget:new{
        book    = self.book,
        width   = self.cover_w,
        height  = cover_h,
        on_tap  = self.on_tap,
        on_hold = self.on_hold,
    }

    local right_w = self.width - self.cover_w - Size.padding.default
    local title = TextBoxWidget:new{
        text  = self.book.title or "Untitled",
        face  = Font:getFace("infofont", 26),
        width = right_w,
        bold  = true,
    }
    -- KOReader's TextBoxWidget doesn't support italic; render upright.
    -- italic deferred to font-face work in a future revision
    local author = TextBoxWidget:new{
        text  = self.book.author or "",
        face  = Font:getFace("infofont", 16),
        width = right_w,
    }

    -- Content stacked from the top: title, author, token detail lines.
    local right_top = VerticalGroup:new{ align = "left", title, author }

    -- Token-rendered detail lines.
    -- Tokens.isEmpty is consulted before adding each widget so empty lines auto-hide.
    if self.lines then
        for _, line in ipairs(self.lines) do
            local rendered = Tokens.expand(line, self.book, self.device_state)
            if not Tokens.isEmpty(rendered) then
                -- Strip v0.1 inline format tags ([b][i][u]) before display.
                -- TextBoxWidget has no markup renderer in v0.1; a future revision
                -- may parse these and apply per-segment bold/italic/underline.
                local display = rendered:gsub("%[/?[biu]%]", "")
                right_top[#right_top + 1] = TextBoxWidget:new{
                    text  = display,
                    face  = Font:getFace("infofont", 14),
                    width = right_w,
                }
            end
        end
    end

    -- Progress bar anchored to the bottom of the right column.
    -- book.book_pct is a 0..1 float from DocSettings "percent_finished".
    -- ProgressWidget's `percentage` also expects 0..1 — no conversion needed.
    local right_bottom
    if self.book.book_pct then
        right_bottom = ProgressWidget:new{
            width      = right_w,
            height     = Size.line.progress,   -- ~7dp, slightly thicker than focus_indicator
            percentage = self.book.book_pct,
            margin_h   = 0,
            margin_v   = 0,
        }
    end

    -- Compose right column: top content + bottom-anchored progress bar.
    -- OverlapGroup with TopContainer/BottomContainer fills the full cover height,
    -- placing content at the top and the progress bar at the bottom with empty
    -- space between them rather than below the content.
    local right_dimen = Geom:new{ w = right_w, h = cover_h }
    local right
    if right_bottom then
        right = OverlapGroup:new{
            dimen = right_dimen,
            TopContainer:new{ dimen = right_dimen, right_top },
            BottomContainer:new{ dimen = right_dimen, right_bottom },
        }
    else
        right = TopContainer:new{ dimen = right_dimen, right_top }
    end

    return HorizontalGroup:new{ align = "top", cover, right }
end

function HeroCard:onTap()  if self.on_tap  then self.on_tap(self.book)  end; return true end
function HeroCard:onHold() if self.on_hold then self.on_hold(self.book) end; return true end

return HeroCard
