-- bookshelf_cover_progress.lua
-- Pure decision logic for per-book progress indicators (bar + glyphs).
--
-- decide(book) maps a book's KOReader sidecar status + percent to a render
-- intent: whether to draw a top-edge progress bar, what fill ratio, and
-- which (if any) status glyph to overlay. Master toggle from
-- G_reader_settings["bookshelf_progress_enabled"].
--
-- Widget builders (buildBarWidget, buildGlyphWidget) live in this file
-- alongside the decision logic so SpineWidget has a single require to
-- pull in everything it needs.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local Blitbuffer
local Device
local Font
local FrameContainer
local Geom
local OverlapGroup
local TextWidget
local Widget
local Colour
local ffi
local ColorRGB32_t
local Screen
local ProgressBarWidget

local function _ensureWidgetDeps()
    if Screen then return end
    Blitbuffer     = require("ffi/blitbuffer")
    Device         = require("device")
    Font           = require("ui/font")
    FrameContainer = require("ui/widget/container/framecontainer")
    Geom           = require("ui/geometry")
    OverlapGroup   = require("ui/widget/overlapgroup")
    TextWidget     = require("ui/widget/textwidget")
    Widget         = require("ui/widget/widget")
    Colour         = require("lib/bookshelf_colour")
    local ok_ffi, ffi_mod = pcall(require, "ffi")
    ffi = ok_ffi and ffi_mod or {
        typeof = function(name) return name end,
        istype = function(kind, value)
            return kind == "ColorRGB32"
                and type(value) == "table"
                and value._kind == "ColorRGB32"
        end,
    }
    ColorRGB32_t = ffi.typeof("ColorRGB32")
    Screen = Device.screen
end

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished

-- Cover-badge font scale. Single source of truth for the page-count
-- pill, series-number pill, ×N count badge, and completed-tickbox
-- glyph. Read inline (not memoised) so settings menu nudge dialogs see
-- the new value on the next paint without a require cycle.
function M.badgeSize(base)
    local scale = BookshelfSettings.read("cover_badge_font_scale") or 100
    return math.floor(base * scale / 100 + 0.5)
end

-- Read a per-element toggle. All three default ON (true) when unset.
-- Setting keys (within the bookshelf settings store):
--   progress_bar_enabled       -- the rounded pill at cover bottom
--   progress_bookmark_enabled  -- the in-progress glyph
--   progress_badge_enabled     -- the complete (badged) glyph
local function _toggle(key)
    local v = BookshelfSettings.read(key)
    if v == nil then return true end
    return v == true
end

-- Lazy reference to bookshelf_book_repository for the readProgress fallback
-- below. Required so chip paths that use the light book constructor
-- (buildBookMeta -> no DocSettings read) still get status/pct without the
-- expensive eager attachment.
local _Repo

-- Pure decision with a lazy filepath-based fallback for status/pct.
-- Each output element is independently gated by its own toggle.
-- @param book table|nil with keys `status` (string|nil), `book_pct` (number|nil)
--             and optionally `filepath` (string|nil)
-- @return table { bar=bool, bar_pct=number, glyph=..., page_count=bool }
--   page_count is independent of status -- the page total is meaningful
--   for any book the user might browse, not just one that's been opened.
function M.decide(book)
    -- progress_page_count_enabled defaults OFF, distinct from the other
    -- three indicators which default ON via _toggle. _toggle returns true
    -- on nil — wrong default here — so read the raw value and only treat
    -- an explicit `true` as on.
    local want_page_count = BookshelfSettings.read("progress_page_count_enabled") == true
    local none = { bar = false, bar_pct = 0, glyph = nil, page_count = want_page_count }
    if not book then return none end
    local status = book.status
    local pct    = book.book_pct
    -- Most shelf chips (getRecent, getLatest, getAll, ...) use the
    -- light book constructor and don't open DocSettings -- book.status
    -- arrives nil. Same goes for book.page_count on EPUBs: BIM only
    -- knows page counts for pre-paginated formats (PDF / CBR / CBZ);
    -- for reflowed EPUBs the count lives in the sdr sidecar
    -- (pagemap_doc_pages or stats.pages). Repo.readProgress reads
    -- both summary + page count from a single cached DocSettings open,
    -- so the per-cover cost stays bounded by the TTL.
    local need_status_fallback = (status == nil and book.filepath)
    local need_pages_fallback  =
        (want_page_count and not book.page_count and book.filepath)
    if need_status_fallback or need_pages_fallback then
        if not _Repo then _Repo = require("lib/bookshelf_book_repository") end
        local p, s, _r, pages = _Repo.readProgress(book.filepath)
        if need_status_fallback then
            pct    = pct or p
            status = s
        end
        -- Mutate book.page_count so the SpineWidget renderer (which
        -- reads self.book.page_count directly) picks it up without a
        -- second lookup, and subsequent decide() calls skip the
        -- readProgress branch entirely.
        if need_pages_fallback and pages then
            book.page_count = pages
        end
    end
    local want_bar      = _toggle("progress_bar_enabled")
    local want_bookmark = _toggle("progress_bookmark_enabled")
    -- Completed-badge style is tri-state: "none" / "bookmark" (the pre-v2.1
    -- outlined dangling check) / "tickbox" (the v2.1 square pill, default
    -- in this fork). New key wins when set; otherwise fall back to the
    -- legacy boolean progress_badge_enabled (true / nil -> tickbox,
    -- false -> none) so users who had the badge off stay off, and existing
    -- fork installs keep the same finished-cover look after merging upstream.
    local badge_style = BookshelfSettings.read("progress_badge_style")
    if badge_style == nil then
        local legacy = BookshelfSettings.read("progress_badge_enabled")
        if legacy == false then
            badge_style = "none"
        else
            badge_style = "tickbox"
        end
    end
    -- Status vocabulary is normalised upstream (Repo.readProgress /
    -- Repo.buildBook). KOReader stores 'complete' / 'abandoned' in the
    -- sidecar; bookshelf treats those as 'finished' / 'on_hold' across
    -- the filter UI, sort engine, and cover indicators. Either name
    -- accepted here for back-compat with any cached records that
    -- predate the normalisation.
    if status == "reading" or status == "abandoned" or status == "on_hold" then
        return {
            bar        = want_bar and (pct ~= nil),
            bar_pct    = pct or 0,
            glyph      = want_bookmark and "in_progress" or nil,
            page_count = want_page_count,
        }
    elseif status == "complete" or status == "finished" then
        local glyph_kind = nil
        if     badge_style == "bookmark" then glyph_kind = "complete_bookmark"
        elseif badge_style == "tickbox"  then glyph_kind = "complete_tickbox"
        end
        return {
            bar        = false,
            bar_pct    = 0,
            glyph      = glyph_kind,
            page_count = want_page_count,
        }
    end
    -- status = "new" or nil: bar / glyph stay off but page count can
    -- still show -- knowing the page count of an unread book is useful.
    return none
end

-- ---------------------------------------------------------------------------
-- Widget: ProgressBarWidget
-- ---------------------------------------------------------------------------

-- Blitbuffer's plain paintRoundedRect / paintBorder flatten their colour
-- argument to luminance via getColor8() before painting, so a ColorRGB32
-- like red goes down as its grey luminance on a colour buffer. KOReader
-- exposes parallel *RGB32 variants that preserve true colour; dispatch by
-- type so the call sites stay shape-agnostic. (Same pattern bookends uses
-- in bookends_overlay_widget.lua.)
local function _paintRoundedRect(bb, x, y, w, h, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintRoundedRectRGB32(x, y, w, h, c, r)
    else
        bb:paintRoundedRect(x, y, w, h, c, r)
    end
end

local function _paintBorder(bb, x, y, w, h, bw, c, r)
    if not c then return end
    if ffi.istype(ColorRGB32_t, c) then
        bb:paintBorderRGB32(x, y, w, h, bw, c, r)
    else
        bb:paintBorder(x, y, w, h, bw, c, r)
    end
end

local function _getProgressBarWidget()
    if ProgressBarWidget then return ProgressBarWidget end
    _ensureWidgetDeps()
    ProgressBarWidget = Widget:extend{
        width  = 0,
        height = 0,
        pct    = 0,        -- 0..1
        fill   = nil,      -- Blitbuffer colour
        track  = nil,      -- Blitbuffer colour
    }

    function ProgressBarWidget:init()
        self.dimen = Geom:new{ w = self.width, h = self.height }
    end

    function ProgressBarWidget:paintTo(bb, x, y)
        -- Bookends-style rounded pill: track background + dark border outline,
        -- with an inner rounded fill inset by border + small padding. Inner
        -- fill is a smaller pill whose right edge moves with progress.
        local w, h = self.width, self.height
        if w < 1 or h < 1 then return end
        local border = math.max(1, Screen:scaleBySize(1))
        local radius = math.floor(h / 2)
        -- 1. Track background (rounded rect, full bar)
        _paintRoundedRect(bb, x, y, w, h, self.track, radius)
        -- 2. Dark border outlining the track
        _paintBorder(bb, x, y, w, h, border, Blitbuffer.COLOR_BLACK, radius)
        -- 3. Inner fill (rounded), inset by border + padding, width scales with pct
        local clamped = self.pct
        if clamped < 0 then clamped = 0 end
        if clamped > 1 then clamped = 1 end
        if clamped <= 0 or not self.fill then return end
        local padding     = math.max(1, math.floor(h * 0.15))
        local inset       = border + padding
        local inner_max_w = w - 2 * inset
        local inner_h     = h - 2 * inset
        if inner_max_w < 1 or inner_h < 1 then return end
        local inner_w = math.floor(inner_max_w * clamped + 0.5)
        if inner_w < 1 then return end
        local inner_r = math.max(0, radius - inset)
        _paintRoundedRect(bb, x + inset, y + inset, inner_w, inner_h, self.fill, inner_r)
    end

    return ProgressBarWidget
end

-- Build a ProgressBarWidget. `fill` and `track` are Blitbuffer colour
-- objects (Color8 or ColorRGB32); callers resolve them via
-- bookshelf_colour.parseColorValue before calling here.
function M.buildBarWidget(width, height, pct, fill, track)
    return _getProgressBarWidget():new{
        width  = width,
        height = height,
        pct    = pct,
        fill   = fill,
        track  = track,
    }
end

-- ---------------------------------------------------------------------------
-- Widget: GlyphWidget (status indicator)
-- ---------------------------------------------------------------------------

-- Build a single-glyph TextWidget for the in-progress / finished badges.
-- @param glyph_char  one of GLYPH_BOOKMARK / GLYPH_BOOKMARK_CHECK
-- @param size        target glyph height in pixels (already scaled)
-- @param colour      Blitbuffer colour (resolved via bookshelf_colour)
-- @return TextWidget
function M.buildGlyphWidget(glyph_char, size, colour)
    _ensureWidgetDeps()
    return TextWidget:new{
        text    = glyph_char,
        face    = Font:getFace("symbols", size),
        fgcolor = colour,
    }
end

-- Build a halo'd glyph. The glyph is painted in `halo_color` at every
-- cell of a (2*halo_w + 1) x (2*halo_w + 1) offset grid (skipping the
-- centre), then in `centre_color` at the centre. The offset paints
-- create the outline; the centre paint fills the strokes. Used for the
-- 'completed' indicator so the bookmark-check stays legible against any
-- cover artwork without the heavy 'sticker' look of the old badge.
-- `halo_color` / `centre_color` are Blitbuffer colour objects; both
-- default to the legacy BLACK halo / WHITE centre pair so callers that
-- don't pass them keep their existing render.
function M.buildOutlinedGlyphWidget(glyph_char, size, halo_w, halo_color, centre_color)
    _ensureWidgetDeps()
    halo_w = halo_w or 1
    halo_color   = halo_color   or Blitbuffer.COLOR_BLACK
    centre_color = centre_color or Blitbuffer.COLOR_WHITE
    local widget_w = size + 2 * halo_w
    local widget_h = size + 2 * halo_w
    local group = OverlapGroup:new{
        dimen = Geom:new{ w = widget_w, h = widget_h },
    }
    -- Halo offsets in all 8 directions around the centre.
    for dy = -halo_w, halo_w do
        for dx = -halo_w, halo_w do
            if dx ~= 0 or dy ~= 0 then
                group[#group + 1] = FrameContainer:new{
                    bordersize   = 0,
                    padding      = 0,
                    padding_top  = halo_w + dy,
                    padding_left = halo_w + dx,
                    M.buildGlyphWidget(glyph_char, size, halo_color),
                }
            end
        end
    end
    -- Centre glyph.
    group[#group + 1] = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = halo_w,
        padding_left = halo_w,
        M.buildGlyphWidget(glyph_char, size, centre_color),
    }
    return group
end

-- ---------------------------------------------------------------------------
-- Resolved-settings accessor
-- ---------------------------------------------------------------------------

local DEFAULT_FILL     = { grey = 0x40 }
-- Track defaults to pure white so the bar stays clearly distinct from
-- the cover's drop shadow (mid-grey) on monochrome devices.
local DEFAULT_TRACK    = { grey = 0xFF }
-- Bookmark (in-progress glyph) keeps the pre-2.2.5 look — same dark-grey
-- value the glyph picked up when it used to read from progress_fill.
local DEFAULT_BOOKMARK = { grey = 0x40 }
-- Badge defaults preserve the existing hard-coded pill look (black text on
-- a white fill, thin black border) and the halo'd completed-bookmark look
-- (black outline around a white check). Mapping:
--   pill  : background = badge_bg, text + border = badge_fg
--   check : halo       = badge_fg, centre        = badge_bg
local DEFAULT_BADGE_FG = { grey = 0x00 }
local DEFAULT_BADGE_BG = { grey = 0xFF }

-- Memoised resolvers. resolvedColours() is called multiple times per
-- cover paint (once per active indicator type per cover), and each call
-- used to do seven BookshelfSettings.reads + five parseColorValue calls
-- + a fresh table allocation. With a 20-cover grid that's ~100+ rebuilds
-- per repaint of an unchanged setting state. Cache keyed on:
--
--   * settings generation (bumped by BookshelfSettings.save / .delete)
--   * Screen:isColorEnabled() (hex resolves differently under colour vs
--     greyscale; the parseColorValue hex cache also self-flushes on
--     mode change, but we have to invalidate too or we'd return a
--     ColorRGB32 on a now-greyscale screen)
--
-- Returned tables are SHARED, not freshly allocated — callers must not
-- mutate them. Every current consumer is read-only.
--
-- folder_bg / folder_fg differ from the other fields: they return nil
-- when the setting is unset so the FolderCard render path can fall back
-- to its existing device-aware defaults (manilla on colour panels, dark
-- grey on B&W e-ink, see lib/bookshelf_folder_card.lua's CARDBOARD
-- constant). A static hex default here can't represent that split.
local _resolved_cache, _resolved_gen, _resolved_mode
local _raw_cache, _raw_gen

function M.resolvedColours()
    _ensureWidgetDeps()
    local gen      = BookshelfSettings.generation()
    local is_colour = Screen:isColorEnabled()
    if _resolved_cache and _resolved_gen == gen and _resolved_mode == is_colour then
        return _resolved_cache
    end
    local fill_raw     = BookshelfSettings.read("progress_fill")  or DEFAULT_FILL
    local track_raw    = BookshelfSettings.read("progress_track") or DEFAULT_TRACK
    local bookmark_raw = BookshelfSettings.read("bookmark_color") or DEFAULT_BOOKMARK
    local badge_fg_raw = BookshelfSettings.read("badge_fg")       or DEFAULT_BADGE_FG
    local badge_bg_raw = BookshelfSettings.read("badge_bg")       or DEFAULT_BADGE_BG
    local folder_bg_raw = BookshelfSettings.read("folder_overlay_bg")
    local folder_fg_raw = BookshelfSettings.read("folder_overlay_fg")
    _resolved_cache = {
        fill      = Colour.parseColorValue(fill_raw,     is_colour),
        track     = Colour.parseColorValue(track_raw,    is_colour),
        bookmark  = Colour.parseColorValue(bookmark_raw, is_colour),
        badge_fg  = Colour.parseColorValue(badge_fg_raw, is_colour),
        badge_bg  = Colour.parseColorValue(badge_bg_raw, is_colour),
        folder_bg = folder_bg_raw and Colour.parseColorValue(folder_bg_raw, is_colour) or nil,
        folder_fg = folder_fg_raw and Colour.parseColorValue(folder_fg_raw, is_colour) or nil,
    }
    _resolved_gen  = gen
    _resolved_mode = is_colour
    return _resolved_cache
end

-- Returns the raw setting values (storage shape, not Blitbuffer). For
-- the settings menu's "currently set to..." label rendering. Folder
-- colours return the raw value or nil (no static default) so the menu's
-- valueLabel helper can show "default" when unset. Memoised on the same
-- generation counter as resolvedColours().
function M.rawColours()
    local gen = BookshelfSettings.generation()
    if _raw_cache and _raw_gen == gen then
        return _raw_cache
    end
    _raw_cache = {
        fill      = BookshelfSettings.read("progress_fill")  or DEFAULT_FILL,
        track     = BookshelfSettings.read("progress_track") or DEFAULT_TRACK,
        bookmark  = BookshelfSettings.read("bookmark_color") or DEFAULT_BOOKMARK,
        badge_fg  = BookshelfSettings.read("badge_fg")       or DEFAULT_BADGE_FG,
        badge_bg  = BookshelfSettings.read("badge_bg")       or DEFAULT_BADGE_BG,
        folder_bg = BookshelfSettings.read("folder_overlay_bg"),
        folder_fg = BookshelfSettings.read("folder_overlay_fg"),
        fill_default     = DEFAULT_FILL,
        track_default    = DEFAULT_TRACK,
        bookmark_default = DEFAULT_BOOKMARK,
        badge_fg_default = DEFAULT_BADGE_FG,
        badge_bg_default = DEFAULT_BADGE_BG,
    }
    _raw_gen = gen
    return _raw_cache
end

return M
