-- bookshelf_reviews_modal.lua
-- A small modal that renders Hardcover review HTML (built + sanitised by
-- bookshelf_tokens.reviewsHtml) through KOReader's MuPDF-backed
-- ScrollHtmlWidget, so reviewer names can be italic, headers bold, and the
-- review body keeps its own paragraph/emphasis formatting.
--
-- This replaces the previous plain-text TextViewer for reviews: TextViewer
-- has no inline markup. We keep a title bar plus Refresh / Close buttons and
-- close on a tap outside the frame, mirroring the standard popup idiom.

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FontList        = require("fontlist")
local FrameContainer  = require("ui/widget/container/framecontainer")
local ffiutil         = require("ffi/util")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size            = require("ui/size")
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local Screen          = Device.screen
local _               = require("lib/bookshelf_i18n").gettext

-- Minimal stylesheet for the MuPDF HTML renderer. Keep it conservative --
-- the engine supports a CSS subset. The body margin gives a little side
-- breathing room since the frame itself has no inner horizontal padding.
local REVIEW_CSS = [[
    body   { margin: 0 0.6em; padding: 0; font-family: sans-serif; }
    h1     { font-size: 1.8em; margin: 0 0 0.15em 0; padding: 0; }
    p      { margin: 0.35em 0; text-align: left; }
    .stars   { font-family: "nerdstars"; font-size: 1.15em; }
    p.stars  { margin: 0.5em 0 0.05em 0; }
    p.rating { margin: 0 0 0.5em 0; }
    p.byline { margin: 0 0 0.25em 0; }
    hr     { border: 0; border-top: 1px solid #888888; margin: 0.7em 0 0.4em 0; }
    i, em       { font-style: italic; }
    b, strong   { font-weight: bold; }
    blockquote  { margin: 0.4em 1em; color: #444444; }
    ul, ol      { margin: 0.3em 0 0.3em 1.2em; }
]]

local ReviewsModal = InputContainer:extend{
    title      = nil,
    html_body  = nil,
    width      = nil,
    height     = nil,
    on_refresh = nil,   -- optional callback fired by the Refresh button
}

function ReviewsModal:init()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    -- Near-fullscreen with the standard screen-edge inset (matches TextViewer).
    self.width  = self.width  or (screen_w - Screen:scaleBySize(30))
    self.height = self.height or (screen_h - Screen:scaleBySize(30))

    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
                },
            },
        }
    end

    self.titlebar = TitleBar:new{
        width            = self.width,
        align            = "left",
        with_bottom_line = true,
        title            = self.title or _("Hardcover reviews"),
        close_callback   = function() self:onClose() end,
        show_parent      = self,
    }

    local buttons = ButtonTable:new{
        width = self.width,
        buttons = {
            {
                {
                    text = _("Refresh"),
                    callback = function()
                        local cb = self.on_refresh
                        self:onClose()
                        if cb then cb() end
                    end,
                },
                {
                    text = _("Close"),
                    callback = function() self:onClose() end,
                },
            },
        },
        show_parent = self,
    }

    local titlebar_h = self.titlebar:getSize().h
    local buttons_h  = buttons:getSize().h
    local html_h     = self.height - titlebar_h - buttons_h
    if html_h < Screen:scaleBySize(80) then
        html_h = Screen:scaleBySize(80)
    end

    -- Embed the Nerd Font symbols face via @font-face so the star rows use the
    -- exact same glyphs (F005/F123/F006) as the ratings UI. MuPDF's HTML engine
    -- doesn't fall back to that font for Private-Use-Area codepoints, but it
    -- DOES honour an @font-face that points at the file directly (same path the
    -- rest of KOReader loads it from). If the font can't be resolved we just
    -- skip the rule and the glyphs fall back to blank -- no crash.
    local css = REVIEW_CSS
    local symbols_path = ffiutil.realpath(FontList.fontdir .. "/nerdfonts/symbols.ttf")
    if symbols_path then
        css = string.format(
            '@font-face { font-family: "nerdstars"; src: url("%s"); }\n%s',
            symbols_path, REVIEW_CSS)
    end

    self.scroll_html = ScrollHtmlWidget:new{
        html_body         = self.html_body or "",
        css               = css,
        default_font_size = Screen:scaleBySize(18),
        width             = self.width,
        height            = html_h,
        dialog            = self,
    }

    -- Separator line between the scrollable reviews and the button row, so
    -- the buttons read as a distinct footer (the title bar already has its
    -- own bottom line).
    local button_separator = LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen = Geom:new{
            w = self.width,
            h = Size.line.medium,
        },
    }

    self.frame = FrameContainer:new{
        background  = Blitbuffer.COLOR_WHITE,
        radius      = Size.radius.window,
        bordersize  = Size.border.window,
        padding     = 0,
        VerticalGroup:new{
            align = "left",
            self.titlebar,
            self.scroll_html,
            button_separator,
            buttons,
        },
    }

    -- Fixed, centred -- no MovableContainer, so it can't be dragged around.
    self[1] = CenterContainer:new{
        dimen = Geom:new{ w = screen_w, h = screen_h },
        self.frame,
    }
end

function ReviewsModal:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.frame.dimen
    end)
    return true
end

function ReviewsModal:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self.frame.dimen
    end)
end

function ReviewsModal:onClose()
    UIManager:close(self)
    return true
end

-- Tap outside the frame closes; taps inside fall through so the
-- ScrollHtmlWidget can handle tap-to-scroll.
function ReviewsModal:onTapClose(_arg, ges)
    if ges and ges.pos and self.frame and self.frame.dimen
            and not ges.pos:intersectWith(self.frame.dimen) then
        self:onClose()
        return true
    end
    return false
end

return ReviewsModal
