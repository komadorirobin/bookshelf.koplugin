-- bookshelf_spine_shelf.lua
-- The "spines" shelf style: books stood edge-on along a shelf line, the way
-- a real bookcase presents them. Width from page count, height from the
-- cover's true aspect, colour from the cover's average tone, the title
-- running up the spine, the series number printed level at the foot the way
-- an encyclopedia set numbers its volumes. Favourites can face outwards
-- (front cover shown), bookstore style.
--
-- NOT lib/bookshelf_spine_widget.lua: that file, despite its name, is the
-- COVER TILE of the cover-grid shelf and predates this view. The pure
-- geometry for this view lives in lib/bookshelf_spine_layout.lua.
--
-- ── Night mode ──────────────────────────────────────────────────────────────
-- Night mode inverts the framebuffer at refresh, so every colour derived
-- from a cover is painted PRE-INVERTED (fill and text together) to display
-- as itself -- the same constantInNight treatment stack_display's ribbon
-- uses. The shelf line is UI chrome and inverts with the rest of the UI.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Screen         = Device.screen
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local Widget         = require("ui/widget/widget")
local logger         = require("logger")
local BFont          = require("lib/bookshelf_fonts")
local CoverProgress  = require("lib/bookshelf_cover_progress")
local SpineLayout    = require("lib/bookshelf_spine_layout")

local SpineShelf = {}

-- Gap between neighbouring spines, dp. Books on a real shelf touch; a hair
-- of daylight keeps the hairline borders from doubling up.
SpineShelf.BOOK_GAP_DP = 2
-- Gap either side of a flattened group's run of spines, dp -- the visual
-- seam that keeps a series reading as a series once its stack is flattened.
SpineShelf.GROUP_GAP_DP = 12
-- The shelf plank under each row, dp.
SpineShelf.SHELF_LINE_DP = 3

-- Rotation for the title run. 90 = reads bottom-to-top ("running up the
-- spine"); if a build's rotatedCopy turns the other way, this is the one
-- constant to flip to 270.
local TITLE_ROTATION = 90

-- White text needs to stay legible on the cover-derived fill, so the fill's
-- Rec.601 luminance is capped here; anything brighter is scaled down
-- preserving hue. 110/255 keeps roughly a 4.5:1 contrast against white.
local MAX_FILL_LUMA = 110

local SAMPLE_STEPS = 8

-- ── Night helpers ───────────────────────────────────────────────────────────

local function _nightMode()
    local ok, night = pcall(function()
        return G_reader_settings and G_reader_settings:isTrue("night_mode")
    end)
    return ok and night or false
end

-- ── Book look: colour + aspect, cached per filepath ─────────────────────────

local _look_cache, _look_count = {}, 0
local LOOK_CACHE_MAX = 600

-- Sampled looks persist across launches: sampling means a full BIM cover
-- decode per book, and a Kindle page of 50+ spines would otherwise pay
-- seconds of flash I/O on every cold page. Loaded lazily once; saved back
-- (in-memory, the store's normal flush cadence persists it) whenever a
-- plan added new samples -- see flushLooks().
local _persist, _persist_dirty
local PERSIST_KEY = "spine_looks"
local PERSIST_MAX = 1200

local function _persistTable()
    if _persist then return _persist end
    local ok, BookshelfSettings = pcall(require, "lib/bookshelf_settings_store")
    if ok and BookshelfSettings and BookshelfSettings.read then
        local t = BookshelfSettings.read(PERSIST_KEY)
        _persist = type(t) == "table" and t or {}
    else
        _persist = {}
    end
    return _persist
end

-- flushLooks() — hand new samples to the settings store (in-memory write;
-- the plugin's action-boundary flushes persist it). Called once per plan,
-- not per sample, so a cold page costs one save.
local function _flushLooks()
    if not _persist_dirty then return end
    _persist_dirty = nil
    pcall(function()
        local BookshelfSettings = require("lib/bookshelf_settings_store")
        local n = 0
        for _k in pairs(_persist) do n = n + 1 end
        if n > PERSIST_MAX then
            -- Whole-table reset rather than LRU bookkeeping: resampling is
            -- the cost of a cold page, once, and only after a library far
            -- larger than the cap has cycled through.
            _persist = {}
            _persist_dirty = nil
            BookshelfSettings.save(PERSIST_KEY, nil)
            return
        end
        BookshelfSettings.save(PERSIST_KEY, _persist)
    end)
end

local function _sampleAverage(bb)
    local n, r, g, b = 0, 0, 0, 0
    local w, h = bb:getWidth(), bb:getHeight()
    if not (w and h and w > 1 and h > 1) then return nil end
    for sy = 0, SAMPLE_STEPS - 1 do
        for sx = 0, SAMPLE_STEPS - 1 do
            local px = math.floor((sx + 0.5) * w / SAMPLE_STEPS)
            local py = math.floor((sy + 0.5) * h / SAMPLE_STEPS)
            local p = bb:getPixel(px, py)
            local c = p and p.getColorRGB32 and p:getColorRGB32() or nil
            if c then
                n = n + 1
                r = r + c.r; g = g + c.g; b = b + c.b
            end
        end
    end
    if n == 0 then return nil end
    return r / n, g / n, b / n
end

local function _contrastClamp(r, g, b)
    local luma = 0.299 * r + 0.587 * g + 0.114 * b
    if luma > MAX_FILL_LUMA and luma > 0 then
        local f = MAX_FILL_LUMA / luma
        r, g, b = r * f, g * f, b * f
    end
    return math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5)
end

-- A coverless book still gets a stable, slightly varied cloth-binding tone
-- (hash of its label) rather than one uniform slab of grey.
local function _fallbackLook(label)
    local h = 5381
    for i = 1, #label do h = (h * 33 + label:byte(i)) % 16777213 end
    local base = 58 + (h % 40)
    local r = base + (h % 23)
    local g = base + (math.floor(h / 23) % 23)
    local b = base + (math.floor(h / 529) % 23)
    return { r = r, g = g, b = b, aspect = nil, sampled = false }
end

local function _aspectFromSizetag(tag)
    if type(tag) ~= "string" then return nil end
    local w, h = tag:match("^(%d+)x(%d+)$")
    w, h = tonumber(w), tonumber(h)
    if w and h and w > 0 then return h / w end
    return nil
end

-- bookLook(book) -> { r, g, b, aspect|nil, sampled }
-- Day-mode colour values; painters apply the night pre-invert.
function SpineShelf.bookLook(book)
    local fp = book and book.filepath
    local label = (book and (book.display_title or book.title)) or "?"
    if not fp then return _fallbackLook(label) end
    local hit = _look_cache[fp]
    if hit then return hit end

    -- A look sampled in a previous session skips the cover decode entirely.
    local kept = _persistTable()[fp]
    if type(kept) == "table" and kept.r then
        local look = { r = kept.r, g = kept.g, b = kept.b,
                       aspect = kept.a, sampled = true }
        look.aspect = look.aspect or _aspectFromSizetag(book.cover_sizetag)
        if _look_count >= LOOK_CACHE_MAX then
            _look_cache, _look_count = {}, 0
        end
        _look_cache[fp] = look
        _look_count = _look_count + 1
        return look
    end

    local look
    local ok = pcall(function()
        local bb, owned = nil, false
        if book.cover_bb then
            bb = book.cover_bb
        else
            local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
            if ok_repo and Repo and Repo.getCoverBB then
                bb = Repo.getCoverBB(fp)
                owned = bb ~= nil
            end
        end
        if bb then
            local r, g, b = _sampleAverage(bb)
            local aspect
            local w, h = bb:getWidth(), bb:getHeight()
            if w and h and w > 0 then aspect = h / w end
            if owned and bb.free then bb:free() end
            if r then
                r, g, b = _contrastClamp(r, g, b)
                look = { r = r, g = g, b = b, aspect = aspect, sampled = true }
            elseif aspect then
                look = _fallbackLook(label)
                look.aspect = aspect
            end
        end
    end)
    if not ok or not look then
        look = _fallbackLook(label)
    end
    look.aspect = look.aspect or _aspectFromSizetag(book.cover_sizetag)

    -- Only a real sample is worth keeping. A fallback usually means the
    -- cover just isn't EXTRACTED yet (first run, BIM still working) --
    -- caching it would pin the placeholder tone past the repaint that
    -- follows extraction.
    if look.sampled then
        if _look_count >= LOOK_CACHE_MAX then
            _look_cache, _look_count = {}, 0
        end
        _look_cache[fp] = look
        _look_count = _look_count + 1
        _persistTable()[fp] = { r = look.r, g = look.g, b = look.b,
                                a = look.aspect }
        _persist_dirty = true
    end
    return look
end

function SpineShelf.dropLook(fp)
    if fp and _look_cache[fp] then
        _look_cache[fp] = nil
        _look_count = math.max(0, _look_count - 1)
    end
    if fp and _persist and _persist[fp] then
        _persist[fp] = nil
        _persist_dirty = true
    end
end

-- ── Favourites ──────────────────────────────────────────────────────────────

local function _isFavourite(fp)
    if not fp then return false end
    local ok, rc = pcall(require, "readcollection")
    return ok and rc and rc.coll and rc.coll.favorites
           and rc.coll.favorites[fp] ~= nil or false
end

-- ── Paint helpers ───────────────────────────────────────────────────────────

local function _fillColor(look, night)
    local r, g, b = look.r, look.g, look.b
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

local function _textColor(night)
    -- Painted pre-inverted in night mode so it always DISPLAYS white.
    return night and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

-- Rotated title: render horizontally into a scratch RGB32 buffer prefilled
-- with the spine colour (so glyph anti-aliasing blends into the right
-- ground), rotate the buffer, blit. Rotation cost is one copy of a
-- text-sized buffer.
local function _paintRotatedTitle(bb, x, y, run_len, band_w, text, face_size, look, night)
    if run_len < Screen:scaleBySize(14) or band_w < 8 then return end
    local ok, err = pcall(function()
        -- Shrink to fit: a narrow spine can't take the nominal size, so step
        -- the face down (never below 6dp) until the rendered line's height
        -- fits across the spine, rather than silently dropping the title.
        local face_name = BFont.getUIFontFace() or "cfont"
        local tw, sz
        local size = face_size
        while size >= 6 do
            tw = TextWidget:new{
                text      = text,
                face      = BFont:getFace(face_name, size),
                fgcolor   = _textColor(night),
                max_width = run_len,
                padding   = 0,
            }
            sz = tw:getSize()
            if sz.h <= band_w then break end
            tw:free()
            tw = nil
            size = size - 2
        end
        if not tw then return end
        local sw = math.min(sz.w, run_len)
        local sh = sz.h
        if sw < 1 or sh < 1 then tw:free() return end
        local scratch = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
        -- NOT scratch:fill() -- fill flattens its colour argument to
        -- luminance via getColor8, which is exactly the washed-out band this
        -- replaced. paintRectRGB32 keeps the true colour.
        scratch:paintRectRGB32(0, 0, sw, sh, _fillColor(look, night))
        tw:paintTo(scratch, 0, 0)
        tw:free()
        local rot = scratch:rotatedCopy(TITLE_ROTATION)
        scratch:free()
        local rw, rh = rot:getWidth(), rot:getHeight()
        -- Centre across the spine, centre along the run.
        local dx = x + math.floor((band_w - rw) / 2)
        local dy = y + math.floor((run_len - rh) / 2)
        bb:blitFrom(rot, dx, dy, 0, 0, rw, rh)
        rot:free()
    end)
    if not ok then
        logger.dbg("[bookshelf perf] spineshelf: title paint failed: " .. tostring(err))
    end
end

-- Level (unrotated) single line centred in the given box; returns height used.
local function _paintLevelText(bb, x, y, box_w, text, face, night)
    local used = 0
    pcall(function()
        local tw = TextWidget:new{
            text      = text,
            face      = face,
            fgcolor   = _textColor(night),
            max_width = box_w,
            padding   = 0,
        }
        local sz = tw:getSize()
        if sz.w >= 1 and sz.h >= 1 then
            tw:paintTo(bb, x + math.floor((box_w - sz.w) / 2), y)
            used = sz.h
        end
        tw:free()
    end)
    return used
end

local function _statusGlyph(book)
    local d
    local ok = pcall(function() d = CoverProgress.decide(book) end)
    if not ok or type(d) ~= "table" then return nil end
    if d.glyph == "in_progress" then return CoverProgress.GLYPH_BOOKMARK end
    if d.glyph == "complete_bookmark" or d.glyph == "complete_tickbox" then
        return CoverProgress.GLYPH_BOOKMARK_CHECK
    end
    if d.on_hold then return CoverProgress.GLYPH_PAUSE_CIRCLE end
    return nil
end

-- ── The slot widget ─────────────────────────────────────────────────────────
-- One book, spine-on (or face-out). Fully custom paint; the InputContainer
-- shell supplies tap/hold/double-tap over the slot's footprint.

local SpineBookSlot = InputContainer:extend{
    book       = nil,   -- the item: a book record OR a group (folder/stack)
    entry      = nil,   -- plan entry: { w, h, w_dp, look, face_out, label }
    width      = nil,   -- slot width px
    height     = nil,   -- row height px (spine stands on the bottom edge)
    callbacks  = nil,   -- the _shelfCallbacks table (on_book_tap, on_series_tap, ...)
    show_series = true,
}

-- Route a gesture to the callback the item's kind wants -- the same
-- dispatch ShelfRow does across its per-kind branches, folded into one
-- lookup because every spine paints the same either way.
local function _itemCallback(cbs, item, gesture)
    if not (cbs and item) then return nil end
    if item.filepath then return cbs["on_book_" .. gesture] end
    local kind = item.kind
    if kind == "folder"   then return cbs["on_folder_" .. gesture] end
    if kind == "author"   then return cbs["on_author_" .. gesture] end
    if kind == "genre"    then return cbs["on_genre_" .. gesture] end
    if kind == "tag"      then return cbs["on_tag_" .. gesture] end
    if kind == "language" then return cbs["on_language_" .. gesture] end
    if kind == "opds_nav" then return cbs["on_opds_nav_" .. gesture] end
    if item.books or item.first_book then return cbs["on_series_" .. gesture] end
    return nil
end

function SpineBookSlot:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        Tap       = { GestureRange:new{ ges = "tap",        range = self.dimen } },
        Hold      = { GestureRange:new{ ges = "hold",       range = self.dimen } },
        DoubleTap = { GestureRange:new{ ges = "double_tap", range = self.dimen } },
    }
end

function SpineBookSlot:getSize() return self.dimen end

function SpineBookSlot:onTap()
    local cb = _itemCallback(self.callbacks, self.book, "tap")
    if cb then cb(self.book) return true end
end

function SpineBookSlot:onHold()
    local cb = _itemCallback(self.callbacks, self.book, "hold")
    if cb then cb(self.book) return true end
end

function SpineBookSlot:onDoubleTap()
    -- Books only: double tap opens directly (#271); groups have no "open".
    if self.book and self.book.filepath and self.callbacks
            and self.callbacks.on_book_open then
        self.callbacks.on_book_open(self.book)
        return true
    end
end

function SpineBookSlot:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local e = self.entry
    local night = _nightMode()
    local spine_w = e.w
    local spine_h = math.min(e.h, self.height)
    local top = y + self.height - spine_h

    -- Selected: the book is pulled up off the plank, the way a hand lifts
    -- it clear of the row. Falls back to a heavier border when the spine
    -- already fills the slot and has no headroom to rise into.
    local lifted = false
    if self.is_selected then
        local lift = math.min(Screen:scaleBySize(10), top - y)
        if lift >= Screen:scaleBySize(3) then
            top = top - lift
            lifted = true
        end
    end

    if e.face_out and e.cover_ok ~= false then
        if self:_paintFaceOut(bb, x, top, spine_w, spine_h, night) then
            self:_paintCoverBadges(bb, x, top, spine_w, spine_h, night)
            return
        end
        -- Cover fetch failed: fall through to a plain spine this paint,
        -- and remember so the next paint doesn't retry the decode.
        e.cover_ok = false
    end

    -- ── The spine proper ────────────────────────────────────────────────
    local hairline = Screen:scaleBySize(1)
    if hairline < 1 then hairline = 1 end
    bb:paintRectRGB32(x, top, spine_w, spine_h, _fillColor(e.look, night))
    local border_c = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bw_px = (self.is_selected and not lifted) and (hairline * 3) or hairline
    bb:paintBorder(x, top, spine_w, spine_h, bw_px, border_c)

    local pad = Screen:scaleBySize(3)
    local cur_top = top + pad
    local bottom = top + spine_h - pad

    -- Status glyph (reading / finished / on hold), level, at the head.
    local glyph = _statusGlyph(self.book)
    local w_dp = e.w_dp or 20
    if glyph then
        local gsize = math.max(8, math.min(14, math.floor(w_dp * 0.5)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w, glyph, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end
    -- Favourite star under it (face-out favourites show the cover instead).
    if e.favourite and not e.face_out then
        local gsize = math.max(7, math.min(12, math.floor(w_dp * 0.42)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w,
                                     CoverProgress.FAV_GLYPH_STAR, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end

    -- Series number at the foot, level, encyclopedia style.
    if self.show_series and e.series_num then
        local ssize = math.max(7, math.min(13, math.floor(w_dp * 0.45)))
        local face = BFont:getFace(BFont.getUIFontFace() or "cfont", ssize)
        -- Measure by painting into position from the bottom: probe height
        -- first with a throwaway paint into nowhere is wasteful; instead
        -- reserve ~1.3em and paint inside it.
        local reserve = Screen:scaleBySize(ssize + 4)
        local sy = bottom - reserve
        _paintLevelText(bb, x, sy + Screen:scaleBySize(2), spine_w,
                        e.series_num, face, night)
        bottom = sy - math.floor(pad / 2)
    end

    -- Title, rotated, in whatever run is left.
    local run = bottom - cur_top
    if run > 0 and e.label and e.label ~= "" then
        local tsize = math.max(8, math.min(18, math.floor(w_dp * 0.5)))
        _paintRotatedTitle(bb, x, cur_top, run, spine_w, e.label, tsize,
                           e.look, night)
    end
end

-- Face-out favourite: the actual front cover at spine height, with the same
-- hairline the cover grid gives it. Returns false when no cover could be
-- painted (caller falls back to a spine).
function SpineBookSlot:_paintFaceOut(bb, x, top, w, h, night)
    local painted = false
    pcall(function()
        local book = self.book
        local src, owned = nil, false
        if book.cover_bb then
            src = book.cover_bb
        else
            local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
            if ok_repo and Repo and Repo.getCoverBB then
                src = Repo.getCoverBB(book.filepath)
                owned = src ~= nil
            end
        end
        if not src then return end
        local scaled = src:scale(w, h)
        if owned and src.free then src:free() end
        if not scaled then return end
        -- Night inverts the framebuffer at refresh; a raw cover blit would
        -- display as a negative. Pre-invert so it comes out as itself --
        -- the same treatment the spine fills get in _fillColor.
        if night and scaled.invertRect then
            scaled:invertRect(0, 0, w, h)
        end
        bb:blitFrom(scaled, x, top, 0, 0, w, h)
        if scaled.free then scaled:free() end
        local hairline = Screen:scaleBySize(1)
        if hairline < 1 then hairline = 1 end
        local border_c = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        -- The lift in paintTo already moved `top`; the hairline stays a
        -- hairline so a lifted cover reads as raised, not outlined.
        bb:paintBorder(x, top, w, h, hairline, border_c)
        painted = true
    end)
    return painted
end

-- Status glyph on a face-out cover, badge style, bottom-left -- the same
-- reading the cover grid gives it, simplified to the spike's needs.
function SpineBookSlot:_paintCoverBadges(bb, x, top, w, h, night)
    local glyph = _statusGlyph(self.book)
    if not glyph then return end
    pcall(function()
        local gsize = 12
        local face = BFont:getFace("symbols", gsize)
        local tw = TextWidget:new{
            text = glyph, face = face,
            fgcolor = _textColor(night), padding = 0,
        }
        local sz = tw:getSize()
        local pad = Screen:scaleBySize(3)
        local bx = x + pad
        local by = top + h - sz.h - pad
        local bg = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        bb:paintRect(bx - math.floor(pad / 2), by - math.floor(pad / 2),
                     sz.w + pad, sz.h + pad, bg)
        tw:paintTo(bb, bx, by)
        tw:free()
    end)
end

-- ── The shelf plank ─────────────────────────────────────────────────────────

local ShelfPlank = Widget:extend{}

function ShelfPlank:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local line_h = Screen:scaleBySize(SpineShelf.SHELF_LINE_DP)
    if line_h < 2 then line_h = 2 end
    bb:paintRect(x, y + self.dimen.h - line_h, self.dimen.w, line_h,
                 Blitbuffer.COLOR_BLACK)
end

-- ── Plan: which books fit which rows, and how wide each stands ──────────────
--
-- plan(items, opts) -> {
--   entries = { {book, w, h, w_dp, look, face_out, favourite, label,
--                series_num}, ... },   -- one per (non-nil) item, in order
--   rows    = { {first,last}, ... },   -- capped at opts.n_rows
--   shown   = <count of books that made it onto this page>,
-- }
-- opts: content_w, row_h (px), gap (px), n_rows, face_out (bool),
--       height_pct (50..100, scales the spine height budget).
function SpineShelf.plan(items, opts)
    local entries = {}
    local budget = opts.row_h
    local pct = tonumber(opts.height_pct)
    if pct and pct >= 30 and pct <= 100 then
        budget = math.floor(budget * pct / 100)
    end
    local book_gap  = opts.gap or 0
    local group_gap = opts.group_gap or book_gap

    -- ── Flatten ─────────────────────────────────────────────────────────
    -- A group that carries its member records (series stack, author /
    -- genre / tag pile) is flattened: every member stands as its own
    -- spine, and the run gets a wider gap on each side so the grouping
    -- still reads on the shelf. Groups that only know their first book
    -- (folders) stay as one drillable spine.
    local flat, n_items = {}, 0
    for i = 1, #items do
        local it = items[i]
        if it then
            n_items = n_items + 1
            local members = it.books
            if members and #members > 0 then
                for m = 1, #members do
                    flat[#flat + 1] = { item = it, book = members[m],
                                        item_idx = n_items,
                                        in_group = #members > 1 }
                end
            else
                flat[#flat + 1] = { item = it, book = it,
                                    item_idx = n_items, in_group = false }
            end
        end
    end

    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    for j = 1, #flat do
        local f = flat[j]
        local bk = f.book
        local rep = bk
        if not bk.filepath then
            rep = bk.first_book or bk
        end
        local label = bk.display_title or bk.title or bk.label
                      or bk.series_name or bk.text or bk.name
        if (not label or label == "") and bk.filename then
            label = bk.filename:gsub("%.%w+$", "")
        end
        if (not label or label == "") and type(bk.filepath) == "string" then
            label = bk.filepath:match("([^/]+)%.%w+$")
                    or bk.filepath:match("([^/]+)$") or ""
        end
        label = label or ""
        local look = SpineShelf.bookLook(rep)
        local aspect = look.aspect
        local h = SpineLayout.spineHeight(budget, aspect)
        local fav = bk.filepath ~= nil and _isFavourite(bk.filepath)
        local face_out = (opts.face_out ~= false) and fav
        -- The light record path leaves page_count nil for reflowables;
        -- the sidecar knows better and CoverProgress.decide reads it at
        -- paint time anyway for the glyphs, through the same TTL cache,
        -- so this backfill costs the page ONE sidecar read per book.
        local pages = bk.page_count
        if not pages and bk.filepath and ok_repo and Repo and Repo.readProgress then
            pcall(function()
                local _pct, _status, _rating, pc = Repo.readProgress(bk.filepath)
                if pc then
                    pages = pc
                    bk.page_count = pc
                end
            end)
        end
        local w_dp, w
        if face_out then
            w = SpineLayout.faceOutWidth(h, aspect)
            w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + 0.5)
        else
            w_dp = SpineLayout.spineWidthDp(pages)
            -- Per-chip thickness: a straight multiplier on the page-count
            -- width. Face-out covers are aspect-true and stay out of it.
            local t = tonumber(opts.thickness_pct)
            if t and t >= 40 and t <= 300 and t ~= 100 then
                w_dp = math.max(8, w_dp * t / 100)
            end
            w = Screen:scaleBySize(w_dp)
        end
        local series_num = nil
        if bk.series_num and tostring(bk.series_num) ~= "" then
            series_num = tostring(bk.series_num)
        end
        -- The gap this spine carries on its left: none at the very start,
        -- the small gap inside a run or between loose books, the wide one
        -- whenever the item boundary being crossed involves a group.
        local gap_before = 0
        if j > 1 then
            local prev = flat[j - 1]
            if prev.item_idx == f.item_idx then
                gap_before = book_gap
            elseif prev.in_group or f.in_group then
                gap_before = group_gap
            else
                gap_before = book_gap
            end
        end
        entries[#entries + 1] = {
            book = bk, item = f.item, item_idx = f.item_idx,
            w = w, h = h, w_dp = w_dp, look = look,
            face_out = face_out, favourite = fav, label = label,
            series_num = series_num, gap_before = gap_before,
        }
        logger.dbg(string.format(
            "[bookshelf perf] spine plan: %-24s w_dp=%.1f pages=%s aspect=%s rgb=%d,%d,%d sampled=%s fav=%s face_out=%s item=%d",
            label:sub(1, 24), w_dp, tostring(pages),
            tostring(aspect and string.format("%.2f", aspect)),
            look.r, look.g, look.b, tostring(look.sampled),
            tostring(fav), tostring(face_out), f.item_idx))
    end

    local widths, gaps = {}, {}
    for i = 1, #entries do
        widths[i] = entries[i].w
        gaps[i]   = entries[i].gap_before
    end
    local rows = SpineLayout.fillRows(widths, opts.content_w, gaps)
    while #rows > (opts.n_rows or 1) do table.remove(rows) end

    -- shown is in ITEM units (what the cursor counts): the last item whose
    -- spines ALL made it onto the page. A group cut off mid-run repeats
    -- from its start on the next page -- with the floor of one so a group
    -- larger than a whole page can still be advanced past.
    local shown = 0
    if #rows > 0 then
        local last_entry = rows[#rows].last
        local last_item = entries[last_entry].item_idx
        local fully = last_entry == #entries
                      or entries[last_entry + 1].item_idx ~= last_item
        shown = fully and last_item or (last_item - 1)
        if shown < 1 then shown = 1 end
    end
    _flushLooks()
    return { entries = entries, rows = rows, shown = shown }
end

-- ── Row widget ──────────────────────────────────────────────────────────────
--
-- rowWidget(opts) -> a width × height widget: shelf plank across the base,
-- spines stood on it. opts: plan, row (a {first,last} slice or nil for an
-- empty row), width, height, gap, on_book_tap/on_book_hold/on_book_open.
function SpineShelf.rowWidget(opts)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local OverlapGroup    = require("ui/widget/overlapgroup")

    local dimen = Geom:new{ w = opts.width, h = opts.height }
    local plank = ShelfPlank:new{ dimen = Geom:new{ w = opts.width, h = opts.height } }
    if not opts.row then
        return OverlapGroup:new{ dimen = dimen, plank }
    end

    -- Books stand ON the plank: their slot stops where the plank starts.
    local line_h = Screen:scaleBySize(SpineShelf.SHELF_LINE_DP)
    if line_h < 2 then line_h = 2 end
    local stand_h = math.max(1, opts.height - line_h)
    local group = HorizontalGroup:new{ align = "top" }
    for i = opts.row.first, opts.row.last do
        local e = opts.plan.entries[i]
        if e then
            if #group > 0 then
                -- Each spine carries its own leading gap: hairline inside a
                -- run, wider across a group boundary. The row's first spine
                -- carries none (fillRows dropped it from the arithmetic too).
                group[#group + 1] = HorizontalSpan:new{
                    width = e.gap_before or opts.gap,
                }
            end
            group[#group + 1] = SpineBookSlot:new{
                book        = e.book,
                entry       = e,
                width       = e.w,
                height      = stand_h,
                callbacks   = opts.callbacks,
                is_selected = opts.selected_filepath ~= nil
                              and e.book.filepath == opts.selected_filepath,
            }
        end
    end
    local result = OverlapGroup:new{ dimen = dimen, plank, group }
    return result
end

SpineShelf._SpineBookSlot = SpineBookSlot  -- for tests

return SpineShelf
