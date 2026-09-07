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

local _gettime
do
    local ok, TimeVal = pcall(require, "ui/timeval")
    if ok and TimeVal and TimeVal.now then
        _gettime = function()
            local tv = TimeVal:now()
            return tv.sec + tv.usec / 1e6
        end
    else
        _gettime = os.clock
    end
end

-- Gap between neighbouring spines, dp. Books on a real shelf touch; a hair
-- of daylight keeps the hairline borders from doubling up.
SpineShelf.BOOK_GAP_DP = 2
-- Gap either side of a flattened group's run of spines, dp -- the visual
-- seam that keeps a series reading as a series once its stack is flattened.
SpineShelf.GROUP_GAP_DP = 12

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

-- Hydrated stub answers (title / series number / pages / author), session
-- lifetime, keyed by filepath: group-member stubs are rebuilt on every
-- fetch, so per-record flags cannot carry this across page turns.
local _hydrate_cache = {}

-- Rendered-slot pixel cache, MODULE level: every page turn builds fresh
-- slot widgets, so a per-instance cache re-rendered the whole page (a
-- rotated-title TextWidget per book) on every turn. Keyed by book +
-- geometry + state; FIFO-evicted at ~3 pages' worth. The cache owns the
-- buffers; slots look up per paint and never free them.
local _render_cache, _render_order = {}, {}
local _render_bytes = 0
-- Byte budget, not a count: a count cap that fits a greyscale device
-- would balloon 4x on an RGB32 screen. ~5MB holds roughly three pages of
-- slots on a PW5.
local RENDER_CACHE_MAX_BYTES = 5 * 1024 * 1024

local function _bbBytes(bbuf)
    local ok, n = pcall(function()
        local bpp = 1
        local t = bbuf.getType and bbuf:getType()
        if t == Blitbuffer.TYPE_BBRGB32 then bpp = 4
        elseif t == Blitbuffer.TYPE_BBRGB24 then bpp = 3
        elseif t == Blitbuffer.TYPE_BBRGB16 or t == Blitbuffer.TYPE_BB8A then bpp = 2
        end
        return bbuf:getWidth() * bbuf:getHeight() * bpp
    end)
    return ok and n or 0
end

local function _renderCacheDrop(key)
    local old_bb = _render_cache[key]
    if not old_bb then return end
    _render_cache[key] = nil
    _render_bytes = _render_bytes - _bbBytes(old_bb)
    pcall(function() old_bb:free() end)
end

local function _renderCachePut(key, bbuf)
    if _render_cache[key] then
        _renderCacheDrop(key)
        _render_order[#_render_order + 1] = key
    else
        _render_order[#_render_order + 1] = key
    end
    _render_cache[key] = bbuf
    _render_bytes = _render_bytes + _bbBytes(bbuf)
    while _render_bytes > RENDER_CACHE_MAX_BYTES and #_render_order > 1 do
        local old_key = table.remove(_render_order, 1)
        _renderCacheDrop(old_key)
    end
end

-- invalidateRender(fp) — drop every cached render of one book (record
-- refresh, cover landing). fp is embedded at the front of each key.
function SpineShelf.invalidateRender(fp)
    if not fp then return end
    local prefix = fp .. "|"
    for i = #_render_order, 1, -1 do
        local key = _render_order[i]
        if key:sub(1, #prefix) == prefix then
            table.remove(_render_order, i)
            _renderCacheDrop(key)
        end
    end
end

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

-- flushLooks() — hand new samples to the settings store, and schedule a
-- REAL disk flush shortly after: an in-memory save is lost when KOReader is
-- killed rather than exited, and every lost look is a cover decode paid
-- again next session (the suspected '5s per page, every session' shape).
local _flush_scheduled
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
        if not _flush_scheduled and BookshelfSettings.flush then
            _flush_scheduled = true
            local ok_ui, UIManager = pcall(require, "ui/uimanager")
            if ok_ui and UIManager then
                UIManager:scheduleIn(3, function()
                    _flush_scheduled = nil
                    pcall(function() BookshelfSettings.flush() end)
                end)
            else
                _flush_scheduled = nil
            end
        end
    end)
end

-- cachedProgress / persistProgress: page count and read status ride the
-- same persisted table as the looks, so a page of spines costs its sidecar
-- reads ONCE ever rather than once per page turn (DocSettings:open is a
-- flash read + parse per book on device). sk marks 'status known', so a
-- never-opened book (status legitimately nil) doesn't re-read its sidecar
-- forever. Invalidation: dropLook (book closed / record refreshed) clears
-- the whole entry, so the next plan re-reads once and re-persists.
function SpineShelf.cachedProgress(fp)
    local e = fp and _persistTable()[fp]
    if not e then return nil, nil, false end
    return e.p, e.s, e.sk == true
end

function SpineShelf.persistProgress(fp, pages, status)
    if not fp then return end
    local t = _persistTable()
    local e = t[fp]
    if not e then
        e = {}
        t[fp] = e
    end
    if pages then e.p = pages end
    e.s = status or nil
    e.sk = true
    _persist_dirty = true
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
            SpineShelf._samples = (SpineShelf._samples or 0) + 1
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

-- invalidateBook(fp) — one entry point for 'this book's metadata changed':
-- drops the persisted look/progress, the hydration answers, and every
-- cached render, so the next plan and paint rebuild it all fresh.
function SpineShelf.invalidateBook(fp)
    if not fp then return end
    SpineShelf.dropLook(fp)
    _hydrate_cache[fp] = nil
    SpineShelf.invalidateRender(fp)
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

-- The spine gradient: darker tint at the left edge to lighter at the right,
-- a very slight rounding light (user request). D is the half-range; the
-- centre column is the base colour, so the contrast clamp still holds where
-- the text sits.
local GRAD_D = 0.13
-- The rotated title band's prefill must carry the same ramp; rotation maps
-- scratch rows to screen columns, and this flag picks the direction (flip
-- if a seam shows mirrored against the body).
local GRAD_BAND_FLIP = false

local function _rampF(col, w)
    local t = (w and w > 1) and (col / (w - 1)) or 0.5
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return (1 - GRAD_D) + 2 * GRAD_D * t
end

-- The plank's base colour: the user's "Shelf plank" pick from the Colors
-- menu, mid grey when unset. Returned as plain rgb so the shading tints
-- can be computed from it. Used by the plank AND by the slots' foot
-- chamfers, which reveal the plank surface behind the book.
local function _plankRGB()
    local r, g, b = 0x8C, 0x8C, 0x8C
    pcall(function()
        local c = CoverProgress.resolvedColors().plank
        local rgb = c and c.getColorRGB32 and c:getColorRGB32()
        if rgb then r, g, b = rgb.r, rgb.g, rgb.b end
    end)
    return r, g, b
end

-- plankBandT(y_rel, surf_h) -> the lit fraction of the plank's top surface
-- at y_rel px below its far edge. ONE quantisation, shared by ShelfPlank and
-- by the slots' lift shadows, so the patch under a lifted book matches the
-- plank around it exactly.
function SpineShelf.plankBandT(y_rel, surf_h)
    local bands = 5
    local i = math.floor(y_rel * bands / math.max(1, surf_h))
    if i < 0 then i = 0 elseif i > bands - 1 then i = bands - 1 end
    return 0.25 + 0.30 * (i / (bands - 1))
end

-- Plank colours are computed in DISPLAY space and pre-inverted for night
-- (constantInNight): painted literally, the frame invert flipped every
-- relationship - the lift shadow displayed LIGHTER than the surface and the
-- front face glowed. The resolved night plank colour (darker by default)
-- now displays exactly as designed.
local function _plankFinish(r, g, b)
    if _nightMode() then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(
        math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5), 0xFF)
end

local function _plankShade(f)
    local r, g, b = _plankRGB()
    return _plankFinish(r * f, g * f, b * f)
end

local function _plankLit(t, mul)
    local r, g, b = _plankRGB()
    r = r + (255 - r) * t
    g = g + (255 - g) * t
    b = b + (255 - b) * t
    if mul then r, g, b = r * mul, g * mul, b * mul end
    return _plankFinish(r, g, b)
end

local function _tintColor(look, f, night)
    local r = math.floor(math.min(255, look.r * f) + 0.5)
    local g = math.floor(math.min(255, look.g * f) + 0.5)
    local b = math.floor(math.min(255, look.b * f) + 0.5)
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

-- Rotated title: render horizontally into a scratch RGB32 buffer prefilled
-- with the spine colour (so glyph anti-aliasing blends into the right
-- ground), rotate the buffer, blit. Rotation cost is one copy of a
-- text-sized buffer.
local function _paintRotatedTitle(bb, x, y, run_len, band_w, text, face_size, look, night, author)
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
        local title_w = math.min(sz.w, run_len)
        local sh = sz.h
        if title_w < 1 or sh < 1 then tw:free() return end
        -- The author rides the same band in a smaller face, above the title
        -- the way a printed spine sets it -- only when the title left it a
        -- worthwhile stretch of spine to sit on.
        local atw, asz, author_w = nil, nil, 0
        local seg_gap = Screen:scaleBySize(10)
        if author and author ~= "" then
            local avail = run_len - title_w - seg_gap
            if avail >= Screen:scaleBySize(28) then
                local asize = math.max(6, size - 3)
                atw = TextWidget:new{
                    text      = author,
                    face      = BFont:getFace(face_name, asize),
                    fgcolor   = _textColor(night),
                    max_width = avail,
                    padding   = 0,
                }
                asz = atw:getSize()
                if asz.w < 1 or asz.h > band_w then
                    atw:free()
                    atw = nil
                else
                    author_w = math.min(asz.w, avail)
                end
            end
        end
        local sw = title_w + (atw and (seg_gap + author_w) or 0)
        local scratch = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
        -- NOT scratch:fill() -- fill flattens its colour argument to
        -- luminance via getColor8. Each scratch ROW becomes a screen COLUMN
        -- after rotation, so the prefill carries the body's gradient ramp
        -- row-by-row -- a flat band would sit as a stripe on the gradient.
        local band_off = math.floor((band_w - sh) / 2)
        for ry = 0, sh - 1 do
            local jx = GRAD_BAND_FLIP and (sh - 1 - ry) or ry
            scratch:paintRectRGB32(0, ry, sw, 1,
                _tintColor(look, _rampF(band_off + jx, band_w), night))
        end
        tw:paintTo(scratch, 0, 0)
        tw:free()
        if atw then
            atw:paintTo(scratch, title_w + seg_gap,
                        math.floor((sh - asz.h) / 2))
            atw:free()
        end
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
    if book and book._spine_status_checked and book.status == nil then
        -- Checked at plan time and genuinely never opened: nothing for
        -- decide() to say, and its lazy fallback would re-open the sidecar.
        return nil
    end
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

-- paintTo blits a cached offscreen render. Every setDirty on the shelf
-- repaints the WHOLE widget tree (the refresh region only limits the e-ink
-- update), and a spine render is expensive (a rotated-title TextWidget per
-- book) -- selection taps felt slow because ~30 titles re-rendered per tap.
-- The cache re-renders only when the slot's state key changes; book/look
-- refreshes go through invalidate().
function SpineBookSlot:_renderKey(night)
    local e = self.entry
    local fp = (self.book and self.book.filepath) or self.entry.label or "?"
    return table.concat({
        fp, self.width, self.height, e.w, e.h,
        self.is_selected and "s" or "-",
        night and "n" or "d",
        self.show_author == false and "A" or "a",
    }, "|")
end

function SpineBookSlot:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local night = _nightMode()
    local key = self:_renderKey(night)
    local cached = _render_cache[key]
    if not cached then
        local _tr = _gettime()
        local ok = pcall(function()
            -- Match the screen's buffer type: greyscale devices cache at
            -- 1 byte/px and flatten colour exactly once, colour screens
            -- keep RGB32.
            local btype = (Screen.bb and Screen.bb.getType and Screen.bb:getType())
                          or Blitbuffer.TYPE_BBRGB32
            local c = Blitbuffer.new(self.width, self.height, btype)
            -- Page ground, pre-invert space (white displays black in night
            -- via the frame invert, same as the shelf's own background).
            c:paintRectRGB32(0, 0, self.width, self.height,
                             Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
            self:_renderInto(c, night)
            _renderCachePut(key, c)
            cached = c
        end)
        if not ok or not cached then
            -- Render straight to the target rather than showing nothing.
            self:_renderIntoAt(bb, x, y, night)
            return
        end
        SpineShelf._renders = (SpineShelf._renders or 0) + 1
        SpineShelf._render_ms = (SpineShelf._render_ms or 0)
                                + (_gettime() - _tr) * 1000
    end
    bb:blitFrom(cached, x, y, 0, 0, self.width, self.height)
end

function SpineBookSlot:invalidate()
    -- The pixel cache is module-level and keyed by book; drop every render
    -- of this one (state variants included).
    SpineShelf.invalidateRender(self.book and self.book.filepath)
end

function SpineBookSlot:free()
    -- Nothing owned per instance: renders belong to the module cache and
    -- outlive the widget precisely so page turns can reuse them.
end

function SpineBookSlot:_renderInto(bb, night)
    self:_renderIntoAt(bb, 0, 0, night)
end

function SpineBookSlot:_renderIntoAt(bb, x, y, night)
    local e = self.entry
    local spine_w = e.w
    local spine_h = math.min(e.h, self.height)
    local top = y + self.height - spine_h

    -- Selected: the book is pulled up off the plank, the way a hand lifts
    -- it clear of the row -- with DAYLIGHT between its foot and the shelf
    -- (user ruling: the old fixed lift still overlapped the plank's top
    -- surface). The lift is the surface's height above the feet plus an
    -- air gap; a book too tall to have that headroom shrinks a few percent
    -- while held instead of staying overlapped.
    local lifted = false
    if self.is_selected then
        local pk = self.plank
        local clear = (pk and (3 * pk.b - pk.inset) or Screen:scaleBySize(18))
                      + Screen:scaleBySize(6)
        if spine_h > self.height - clear then
            spine_h = math.max(Screen:scaleBySize(40), self.height - clear)
        end
        top = y + self.height - spine_h - clear
        if top < y then top = y end
        lifted = true
    end

    -- ── The spine proper ────────────────────────────────────────────────
    local hairline = Screen:scaleBySize(1)
    if hairline < 1 then hairline = 1 end
    -- Top edge: the sliver of page block you see looking at a real shelf.
    -- Cover boards (spine colour) run up the sides and past the paper by a
    -- lip; between them, fine vertical stripes alternate paper tones. Lives
    -- INSIDE the book's allotted height, so layout is untouched; tiny
    -- spines skip it.
    local edge_h = 0
    if spine_h >= Screen:scaleBySize(60) then
        edge_h = math.floor(spine_h * 0.05)
        local e_min, e_max = Screen:scaleBySize(5), Screen:scaleBySize(14)
        if edge_h < e_min then edge_h = e_min end
        if edge_h > e_max then edge_h = e_max end
    end
    local body_top = top + edge_h
    local body_h = spine_h - edge_h
    for i = 0, spine_w - 1 do
        bb:paintRectRGB32(x + i, body_top, 1, body_h,
                          _tintColor(e.look, _rampF(i, spine_w), night))
    end
    local border_c = night and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintBorder(x, body_top, spine_w, spine_h - edge_h, hairline, border_c)
    -- Soften the meeting with the plank: the bottom corner pixels come off,
    -- the hint of a chamfer where the book stands. Only while it STANDS --
    -- a lifted book floats in front of the page, and the plank-toned nicks
    -- read as white specks cut into its corners there.
    if not lifted then
        local nick_c = _plankLit(0.5)
        local by = body_top + body_h - hairline
        bb:paintRectRGB32(x, by, hairline, hairline, nick_c)
        bb:paintRectRGB32(x + spine_w - hairline, by, hairline, hairline, nick_c)
    end
    -- A lifted book leaves its shadow on the plank where it stood. The
    -- under-strip REPRODUCES the plank's banded surface (same quantisation,
    -- via plankBandT) and darkens those same bands for the shadow, so the
    -- patch is indistinguishable from the shelf around it; above the
    -- surface's far edge the page ground stays. Row-by-row, but the render
    -- is cached per slot.
    if lifted and self.plank then
        local foot = body_top + body_h
        local slot_bottom = y + self.height
        local surf_h = 3 * self.plank.b
        local surf_top = slot_bottom + self.plank.inset - surf_h
        local start = math.max(foot, surf_top)
        local air_end = math.min(foot + math.max(2, hairline), slot_bottom)
        local ins = hairline * 2
        for yy = start, slot_bottom - 1 do
            local t = SpineShelf.plankBandT(yy - surf_top, surf_h)
            if yy < air_end or spine_w <= 2 * ins then
                bb:paintRectRGB32(x, yy, spine_w, 1, _plankLit(t))
            else
                bb:paintRectRGB32(x, yy, ins, 1, _plankLit(t))
                bb:paintRectRGB32(x + ins, yy, spine_w - 2 * ins, 1,
                                  _plankLit(t, 0.72))
                bb:paintRectRGB32(x + spine_w - ins, yy, ins, 1, _plankLit(t))
            end
        end
    end
    if edge_h > 0 then
        local lip     = math.max(2, math.floor(edge_h * 0.22))
        local board_w = math.max(2, math.min(Screen:scaleBySize(3),
                                             math.floor(spine_w * 0.1)))
        local function tone(v)
            if night then v = 255 - v end
            return Blitbuffer.ColorRGB32(v, v, v, 0xFF)
        end
        local sx0 = x + board_w
        local sw_edge = spine_w - 2 * board_w
        local sy0 = top + lip
        local sh_edge = edge_h - lip
        if sw_edge > 2 and sh_edge > 1 then
            -- Stripe pitch and tones sized for e-ink: 1px alternation at
            -- 300dpi dithers into a wash (user report), so the stripes are
            -- DPI-scaled and the tones far enough apart to survive 16 greys.
            -- Fine page LINES on paper. Tighter than the comb-fix pass, with
            -- widths that VARY per line (1px up to the pitch) so the block
            -- reads as pressed paper rather than a printed pattern.
            local sp = math.max(2, math.floor(Screen:scaleBySize(1.4)))
            bb:paintRectRGB32(sx0, sy0, sw_edge, sh_edge, tone(0xF0))
            for cx = sx0 + 1, sx0 + sw_edge - 1, sp + 1 do
                local lw = 1 + ((cx * 73 + 41) % sp)
                lw = math.min(lw, sx0 + sw_edge - cx)
                bb:paintRectRGB32(cx, sy0, lw, sh_edge, tone(0xA8))
            end
        end
        -- The boards, rising the lip above the paper.
        bb:paintRectRGB32(x, top, board_w, edge_h, _fillColor(e.look, night))
        bb:paintRectRGB32(x + spine_w - board_w, top, board_w, edge_h,
                          _fillColor(e.look, night))
    end

    local pad = Screen:scaleBySize(3)
    local cur_top = body_top + pad
    local bottom = top + spine_h - pad

    -- Status glyph (reading / finished / on hold), level, at the head.
    local glyph = _statusGlyph(self.book)
    local w_dp = e.w_dp or 20
    if glyph then
        local gsize = math.max(9, math.min(17, math.floor(w_dp * 0.6)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w, glyph, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end
    -- Favourite star under it (face-out favourites show the cover instead).
    if e.favourite and not e.face_out then
        local gsize = math.max(8, math.min(14, math.floor(w_dp * 0.5)))
        local face = BFont:getFace("symbols", gsize)
        local used = _paintLevelText(bb, x, cur_top, spine_w,
                                     CoverProgress.FAV_GLYPH_STAR, face, night)
        if used > 0 then cur_top = cur_top + used + math.floor(pad / 2) end
    end

    -- Series number at the foot, level, encyclopedia style: measured, then
    -- anchored so the text BOTTOM sits one pad above the spine's foot --
    -- the reserve arithmetic this replaces drifted with font size and let
    -- the number float above the base.
    if self.show_series and e.series_num then
        local ssize = math.max(7, math.min(13, math.floor(w_dp * 0.45)))
        local face = BFont:getFace(BFont.getUIFontFace() or "cfont", ssize)
        pcall(function()
            local tw = TextWidget:new{
                text = e.series_num, face = face,
                fgcolor = _textColor(night),
                max_width = spine_w, padding = 0,
            }
            local sz = tw:getSize()
            if sz.w >= 1 and sz.h >= 1 and sz.h < spine_h / 2 then
                local sy = top + spine_h - pad - sz.h
                tw:paintTo(bb, x + math.floor((spine_w - sz.w) / 2), sy)
                bottom = sy - math.floor(pad / 2)
            end
            tw:free()
        end)
    end

    -- Title, rotated, in whatever run is left.
    local run = bottom - cur_top
    if run > 0 and e.label and e.label ~= "" then
        local tsize = math.max(8, math.min(18, math.floor(w_dp * 0.5)))
        local author = (self.show_author ~= false) and e.author or nil
        _paintRotatedTitle(bb, x, cur_top, run, spine_w, e.label, tsize,
                           e.look, night, author)
    end
end

-- A lifted face-out's shadow on the plank: transparent except for the
-- darker patch, so the plank's own shading shows around it. The patch
-- darkens the SAME banded tones the plank paints at those rows (via the
-- shared plankBandT), so it matches the shadow under a lifted spine.
local LiftShadow = Widget:extend{}

function LiftShadow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local ins = Screen:scaleBySize(2)
    local pk = self.plank
    if pk then
        -- The shadow lies ON the plank's top surface, never in the air the
        -- book lifted through: painting the whole drop made it stick up
        -- past the shelf's back edge (user report). Clamp to the surface
        -- band, darkening the same tones the plank paints there.
        local surf_h = 3 * pk.b
        local surf_top = y + h + pk.inset - surf_h
        local y0 = math.max(y, surf_top)
        for yy = y0, y + h - 1 do
            local t = SpineShelf.plankBandT(yy - surf_top, surf_h)
            bb:paintRectRGB32(x + ins, yy, math.max(1, w - 2 * ins), 1,
                              _plankLit(t, 0.72))
        end
        return
    end
    local air = math.max(2, Screen:scaleBySize(1))
    local sh = math.min(self.shadow_h or 0, h - air)
    if sh < 1 then return end
    bb:paintRectRGB32(x + ins, y + air, math.max(1, w - 2 * ins), sh,
                      _plankLit(0.4, 0.72))
end

-- ── Face-out page block ─────────────────────────────────────────────────────
-- The book's top edge above a face-out cover: fine vertical page stripes,
-- with the cover board as a border on the LEFT edge and across the TOP (the
-- back board seen edge-on). Its height is the book's thickness -- the same
-- page-count width its spine would have had. Replaces the cover tile's drop
-- shadow, which read as floating rather than shelved.
local FaceOutTopBlock = Widget:extend{}

function FaceOutTopBlock:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if w < 6 or h < 3 then return end
    local night = _nightMode()
    local board = math.max(2, math.min(Screen:scaleBySize(3),
                                       math.floor(h * 0.3)))
    local function tone(v)
        if night then v = 255 - v end
        return Blitbuffer.ColorRGB32(v, v, v, 0xFF)
    end
    -- Pages first, boards left / top / a thin sliver right, so the block
    -- reads as pages BETWEEN the cover boards like a spine top does. The
    -- stripes run HORIZONTALLY here: a face-out book's pages stack front to
    -- back, so their edges read as lines parallel to the cover's top.
    local rb = math.max(1, math.floor(board / 2))
    local sx0, sy0 = x + board, y + board
    local sw, sh = w - board - rb, h - board
    if sw > 2 and sh > 1 then
        local sp = math.max(2, math.floor(Screen:scaleBySize(1.4)))
        bb:paintRectRGB32(sx0, sy0, sw, sh, tone(0xF0))
        for cy = sy0 + 1, sy0 + sh - 1, sp + 1 do
            local lh = 1 + ((cy * 73 + 41) % sp)
            lh = math.min(lh, sy0 + sh - cy)
            bb:paintRectRGB32(sx0, cy, sw, lh, tone(0xA8))
        end
    end
    local fill = _fillColor(self.look, night)
    -- The top-left corner pixel comes off, the same chamfer the spine feet
    -- get where they meet the plank.
    local ch = math.max(2, Screen:scaleBySize(1))
    bb:paintRectRGB32(x, y + ch, board, h - ch, fill)   -- left board, below the chamfer
    bb:paintRectRGB32(x + ch, y, w - ch, board, fill)   -- top board, right of it
    bb:paintRectRGB32(x + w - rb, y + board, rb, h - board, fill)  -- right sliver
end

-- ── The shelf plank ─────────────────────────────────────────────────────────

local ShelfPlank = Widget:extend{}

-- endMargin(row_h) -> exposed plank at EACH end of a row, px. Books never
-- reach the shelf's ends; the visible margins are what make the plank read
-- as a piece of furniture rather than a stripe (user ruling, promoted from
-- a happy accident on partial rows).
function SpineShelf.endMargin(row_h)
    return SpineShelf.plankUnit(row_h)
end

-- plankUnit(row_h) -> the plank's edge unit in px: roughly one page-block
-- height, derived from the row like the slots derive theirs.
function SpineShelf.plankUnit(row_h)
    local b = math.floor((row_h or 0) * 0.02)
    local bmin, bmax = Screen:scaleBySize(4), Screen:scaleBySize(9)
    if b < bmin then b = bmin end
    if b > bmax then b = bmax end
    return b
end

-- The plank in 3D (user spec): the upward-facing top surface rises TWO edge
-- units behind the books, the front-top edge is a thin dark line, and below
-- it the plank's front face drops one unit, darker. Shading is derived from
-- the one plank colour: surface lit, face in shade, edge darkest.
function ShelfPlank:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    local b = SpineShelf.plankUnit(h)
    local pr, pg, pb = _plankRGB()
    local function shade(f)
        return Blitbuffer.ColorRGB32(
            math.floor(math.min(255, pr * f) + 0.5),
            math.floor(math.min(255, pg * f) + 0.5),
            math.floor(math.min(255, pb * f) + 0.5), 0xFF)
    end
    local front_y = y + h - b
    -- Top surface, receding: darker at the far (top) edge, lighter as it
    -- reaches the front. Three units deep, so the books stand back from
    -- the lip with surface showing in front of their feet.
    local surf_h = 3 * b
    local bands = 5
    for i = 0, bands - 1 do
        local by0 = front_y - surf_h + math.floor(surf_h * i / bands)
        local by1 = front_y - surf_h + math.floor(surf_h * (i + 1) / bands)
        local t = SpineShelf.plankBandT(by0 - (front_y - surf_h), surf_h)
        bb:paintRectRGB32(x, by0, w, by1 - by0, _plankLit(t))
    end
    -- The front-top edge line.
    local line = math.max(1, Screen:scaleBySize(1))
    bb:paintRectRGB32(x, front_y - line, w, line, shade(0.35))
    -- The front face, in shade.
    bb:paintRectRGB32(x, front_y, w, b, shade(0.72))
end

-- _folderIsSingleBook(path) -> true when the folder holds exactly ONE book
-- file and no subfolders -- a wrapper folder (one Calibre-style directory
-- per book), whose spine should read as its book, not as its directory
-- name. Shallow scan, early exit on the second book or any subfolder.
local _folder_single_cache = {}
local function _folderIsSingleBook(path)
    local hit = _folder_single_cache[path]
    if hit ~= nil then return hit end
    local ok, result = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
        if not (ok_repo and Repo and Repo.isBookFile) then return false end
        local count = 0
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
                local mode = lfs.attributes(path .. "/" .. entry, "mode")
                if mode == "directory" then
                    -- KOReader sidecars ride beside their book; only a real
                    -- subfolder makes this a collection.
                    if not entry:match("%.sdr$") then return false end
                elseif mode == "file" and Repo.isBookFile(entry) then
                    count = count + 1
                    if count > 1 then return false end
                end
            end
        end
        return count == 1
    end)
    local single = ok and result == true
    _folder_single_cache[path] = single
    return single
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
    -- Auto thickness: base widths scale with the shelf height, so one tall
    -- row doesn't stand needle-thin books (calibrated on device: two rows =
    -- 1.0, one row wants ~1.5). The chip's thickness % multiplies on top.
    local px_per_dp = Screen:scaleBySize(100) / 100
    local auto_thick = SpineLayout.autoThickness(
        px_per_dp > 0 and (budget / px_per_dp) or nil)
    local book_gap  = opts.gap or 0
    local group_gap = opts.group_gap or book_gap

    -- ── Flatten ─────────────────────────────────────────────────────────
    -- A group that carries its member records (series stack, author /
    -- genre / tag pile) is flattened: every member stands as its own
    -- spine, and the run gets a wider gap on each side so the grouping
    -- still reads on the shelf. Groups that only know their first book
    -- (folders) stay as one drillable spine.
    local _t0 = _gettime()
    local _t_hydrate, _t_look, _t_pages, _t_fav, _n_hydrated = 0, 0, 0, 0, 0
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
        -- A wrapper folder (exactly one book inside) stands on the shelf AS
        -- its book: title, author, number and thickness all come from the
        -- book record; only the tap stays a folder drill. Checked once per
        -- record, cached on it.
        local src = bk
        if bk.kind == "folder" and bk.first_book and bk.path then
            if bk._spine_single == nil then
                bk._spine_single = _folderIsSingleBook(bk.path)
            end
            if bk._spine_single then src = bk.first_book end
        end
        -- A stack member is a LIGHT stub, built from whatever the light-meta
        -- cache held when the group was assembled -- on a cold start that
        -- can predate the Calibre load, so its title can be the filename and
        -- its series number missing while the hero (full record) shows both
        -- cleanly. Hydrate once per stub from the same resolver the hero
        -- uses; the answers are written back onto the stub, which lives in
        -- the group cache, so this costs one metadata read per book ever.
        if f.in_group and bk.filepath and not bk._spine_meta_checked then
            bk._spine_meta_checked = true
            local _th = _gettime()
            -- The stubs are REBUILT on every fetch (the group cache holds
            -- shapes, not records), so a flag on the stub only dedupes
            -- within one plan. The resolver's answers live in a module map
            -- keyed by filepath -- measured before it existed: 76 full
            -- metadata builds per page turn, every page turn.
            local hyd = _hydrate_cache[bk.filepath]
            if not hyd then
                _n_hydrated = _n_hydrated + 1
                pcall(function()
                    if not (ok_repo and Repo and Repo.buildBookMeta) then return end
                    local full = Repo.buildBookMeta(bk.filepath, { want_cover = false })
                    if not full then return end
                    hyd = {
                        display_title = full.display_title,
                        title         = full.title,
                        series_num    = full.series_num
                                        and tostring(full.series_num) or nil,
                        page_count    = full.page_count,
                        cover_sizetag = full.cover_sizetag,
                        author        = full.author,
                    }
                    _hydrate_cache[bk.filepath] = hyd
                end)
            end
            if hyd then
                if hyd.display_title and hyd.display_title ~= "" then
                    bk.display_title = hyd.display_title
                end
                if hyd.title and hyd.title ~= "" then
                    bk.title = hyd.title
                end
                if (not bk.series_num or tostring(bk.series_num) == "")
                        and hyd.series_num and hyd.series_num ~= "" then
                    bk.series_num = hyd.series_num
                end
                if not bk.page_count and hyd.page_count then
                    bk.page_count = hyd.page_count
                end
                if not bk.cover_sizetag and hyd.cover_sizetag then
                    bk.cover_sizetag = hyd.cover_sizetag
                end
                if (not bk.author or bk.author == "") and hyd.author then
                    bk.author = hyd.author
                end
            end
            _t_hydrate = _t_hydrate + (_gettime() - _th)
        end
        local label = src.display_title or src.title or src.label
                      or bk.label or src.series_name or src.text or src.name
        if (not label or label == "") and src.filename then
            label = src.filename:gsub("%.%w+$", "")
        end
        if (not label or label == "") and type(src.filepath) == "string" then
            label = src.filepath:match("([^/]+)%.%w+$")
                    or src.filepath:match("([^/]+)$") or ""
        end
        label = label or ""
        local _tl = _gettime()
        local look = SpineShelf.bookLook(rep)
        _t_look = _t_look + (_gettime() - _tl)
        local aspect = look.aspect
        local h = SpineLayout.spineHeight(budget, aspect)
        local _tf = _gettime()
        local fav = bk.filepath ~= nil and _isFavourite(bk.filepath)
        _t_fav = _t_fav + (_gettime() - _tf)
        local face_out = (opts.face_out ~= false) and fav
        if face_out and src.has_cover == nil and src.filepath
                and ok_repo and Repo and Repo.buildBookMeta then
            -- Light page records carry no has_cover, and the cover tile
            -- gates its whole cover ladder on it (the face-out rendered as
            -- the text placeholder). Face-outs are few: enrich the record
            -- with the full metadata build, missing fields only, cover
            -- pixels still lazy-loaded by the tile.
            pcall(function()
                local full = Repo.buildBookMeta(src.filepath, { want_cover = false })
                if full then
                    for k, v in pairs(full) do
                        if src[k] == nil then src[k] = v end
                    end
                end
            end)
        end
        -- The light record path leaves page_count nil for reflowables;
        -- the sidecar knows better and CoverProgress.decide reads it at
        -- paint time anyway for the glyphs, through the same TTL cache,
        -- so this backfill costs the page ONE sidecar read per book.
        local pages = src.page_count
        do
            local pp, ps, known = SpineShelf.cachedProgress(src.filepath)
            pages = pages or pp
            if src.status == nil and ps then src.status = ps end
            if (not pages or not known) and src.filepath
                    and ok_repo and Repo and Repo.readProgress then
                local _tp = _gettime()
                pcall(function()
                    local _pct, st, _rating, pc = Repo.readProgress(src.filepath)
                    if pc then
                        pages = pc
                        src.page_count = pc
                    end
                    if src.status == nil then src.status = st end
                    SpineShelf.persistProgress(src.filepath, pc, st)
                end)
                _t_pages = _t_pages + (_gettime() - _tp)
            end
            -- The glyph resolver's lazy fallback opens the sidecar whenever
            -- status is nil; a checked record with no status is a book that
            -- has genuinely never been opened.
            src._spine_status_checked = true
        end
        local w_dp, w, depth
        if face_out then
            -- The page block above a face-out cover is the book's THICKNESS:
            -- the same page-count width its spine would have had (auto scale
            -- and the chip's thickness % included), capped so the cover
            -- stays the point.
            local depth_dp = SpineLayout.spineWidthDp(pages) * auto_thick
            local t = tonumber(opts.thickness_pct)
            if t and t >= 40 and t <= 300 and t ~= 100 then
                depth_dp = depth_dp * t / 100
            end
            -- A face-out book shows far less depth than a spine-out one (in
            -- 3D you are looking at its thin edge above the cover): a third
            -- of the spine width, tightly capped.
            depth = math.floor(Screen:scaleBySize(depth_dp) * 0.3)
            local d_max = math.min(math.floor(h * 0.10), Screen:scaleBySize(14))
            if depth > d_max then depth = d_max end
            if depth < Screen:scaleBySize(3) then depth = Screen:scaleBySize(3) end
            w = SpineLayout.faceOutWidth(h - depth, aspect)
            w_dp = math.floor(w / (Screen:scaleBySize(100) / 100) + 0.5)
        else
            w_dp = SpineLayout.spineWidthDp(pages) * auto_thick
            -- Per-chip thickness: a straight multiplier on top of the
            -- height-scaled width. Face-out covers are aspect-true and
            -- stay out of both.
            local t = tonumber(opts.thickness_pct)
            if t and t >= 40 and t <= 300 and t ~= 100 then
                w_dp = w_dp * t / 100
            end
            w_dp = math.max(8, w_dp)
            w = Screen:scaleBySize(w_dp)
        end
        local series_num = nil
        if src.series_num and tostring(src.series_num) ~= "" then
            series_num = tostring(src.series_num)
        end
        -- Filename-style leading index ("2 - Player of Games", "3. Morning
        -- Star"): the last-resort number when metadata has none, and a
        -- duplicate to strip from the spine text when it matches the number
        -- already going to the foot. Guarded to plausible series indices so
        -- "2001: A Space Odyssey" keeps its title.
        if f.in_group then
            local pre, rest = label:match("^%s*(%d+%.?%d*)%s*[%-%.:]%s+(.+)$")
            local n = tonumber(pre)
            if n and n < 100 and rest and #rest > 2 then
                if not series_num then
                    series_num = pre
                end
                -- Strip the prefix even when it DISAGREES with the metadata
                -- number (Culture numbering is contested territory): the
                -- foot is authoritative, and a conflicting index inside the
                -- title reads as two different numbers on one spine.
                label = rest
            end
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
            w = w, h = h, w_dp = w_dp, look = look, depth = depth,
            face_out = face_out, favourite = fav, label = label,
            author = src.author or (src.authors and src.authors[1]) or nil,
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
    SpineShelf._last_plan = {
        total_ms   = (_gettime() - _t0) * 1000,
        entries    = #entries,
        hydrate_ms = _t_hydrate * 1000,
        hydrated   = _n_hydrated,
        look_ms    = _t_look * 1000,
        pages_ms   = _t_pages * 1000,
    }
    logger.dbg(string.format(
        "[bookshelf perf] spine plan TOTAL=%.0fms entries=%d hydrate=%.0fms/%d look=%.0fms pages=%.0fms fav=%.0fms",
        (_gettime() - _t0) * 1000, #entries, _t_hydrate * 1000, _n_hydrated,
        _t_look * 1000, _t_pages * 1000, _t_fav * 1000))
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

    -- Books stand ON the plank's top surface, a step back from the lip:
    -- their feet sit one inset above the front-top edge, so a strip of
    -- surface shows in FRONT of them, the front face drops below that,
    -- and the rest of the surface rises behind (all painted by ShelfPlank
    -- underneath this group).
    local b = SpineShelf.plankUnit(opts.height)
    local inset = math.floor(b * 0.8)
    local stand_h = math.max(1, opts.height - b - inset)
    local group = HorizontalGroup:new{ align = "top" }
    group[#group + 1] = HorizontalSpan:new{
        width = SpineShelf.endMargin(opts.height),
    }
    for i = opts.row.first, opts.row.last do
        local e = opts.plan.entries[i]
        if e then
            if #group > 1 then
                -- Each spine carries its own leading gap: hairline inside a
                -- run, wider across a group boundary. The row's first spine
                -- carries none (fillRows dropped it from the arithmetic too;
                -- the end margin span is group[1]).
                group[#group + 1] = HorizontalSpan:new{
                    width = e.gap_before or opts.gap,
                }
            end
            local is_sel = opts.selected_filepath ~= nil
                           and e.book.filepath == opts.selected_filepath
            local tile
            if e.face_out then
                -- A face-out favourite IS a cover-grid book: reuse the cover
                -- tile wholesale (user ruling) so it carries every glyph,
                -- badge and pill the grid gives it -- bottom-aligned so it
                -- stands on the plank with its neighbours.
                local ok_sw, CoverTile = pcall(require, "lib/bookshelf_spine_widget")
                if ok_sw and CoverTile then
                    local VerticalGroup = require("ui/widget/verticalgroup")
                    local VerticalSpan  = require("ui/widget/verticalspan")
                    -- Face-outs sit a step FURTHER back on the shelf than the
                    -- spines (user ruling), and selection lifts them like any
                    -- other book -- never the cover grid's ring.
                    local push = inset
                    local lift = 0
                    if is_sel then
                        -- Clear the plank's top surface plus an air gap,
                        -- accounting for the extra push face-outs sit at.
                        lift = math.max(0, 3 * b - inset - push)
                               + Screen:scaleBySize(6)
                    end
                    local fo_stand = stand_h - push
                    local depth = math.min(e.depth or 0,
                                           math.max(0, math.min(e.h, fo_stand) - 10))
                    local cover_h = math.min(e.h, fo_stand) - depth
                    -- A tall cover shrinks to make room for the lift rather
                    -- than losing the gap.
                    if lift > 0 and cover_h + depth + lift > fo_stand then
                        cover_h = math.max(Screen:scaleBySize(40),
                                           fo_stand - depth - lift)
                    end
                    local cover = CoverTile:new{
                        book          = e.book,
                        width         = e.w,
                        height        = cover_h,
                        on_tap        = opts.callbacks and opts.callbacks.on_book_tap,
                        on_hold       = opts.callbacks and opts.callbacks.on_book_hold,
                        on_double_tap = opts.callbacks and opts.callbacks.on_book_open,
                        show_progress = true,
                        -- The page block replaces the drop shadow: a shelved
                        -- book doesn't float. flat_thumb drops the shadow AND
                        -- its pixel reservation; badges and glyphs stay.
                        flat_thumb    = true,
                        -- Facing out IS the favourite marker on this shelf;
                        -- the heart badge on top of it doubles the message
                        -- and breaks the skeuomorphism (user ruling).
                        suppress_favorite_badge = true,
                    }
                    local stack = VerticalGroup:new{ align = "center" }
                    local head = fo_stand - cover_h - depth - lift
                    if head > 0 then
                        stack[#stack + 1] = VerticalSpan:new{ width = head }
                    end
                    if depth > 0 then
                        stack[#stack + 1] = FaceOutTopBlock:new{
                            dimen = Geom:new{ w = e.w, h = depth },
                            look  = e.look,
                        }
                    end
                    stack[#stack + 1] = cover
                    if push + lift > 0 then
                        if lift > 0 then
                            -- The lifted book's shadow where it stood.
                            stack[#stack + 1] = LiftShadow:new{
                                dimen    = Geom:new{ w = e.w, h = push + lift },
                                shadow_h = lift,
                                plank    = { b = b, inset = inset },
                            }
                        else
                            stack[#stack + 1] = VerticalSpan:new{
                                width = push + lift,
                            }
                        end
                    end
                    -- Mark the wrapper so the selection repaint can find it
                    -- (it has no .entry; flips fall back to a full swap).
                    stack.book = e.book
                    tile = stack
                end
            end
            if not tile then
                tile = SpineBookSlot:new{
                    book        = e.book,
                    entry       = e,
                    width       = e.w,
                    height      = stand_h,
                    callbacks   = opts.callbacks,
                    show_author = opts.show_author,
                    is_selected = is_sel,
                    plank       = { b = b, inset = inset },
                }
            end
            group[#group + 1] = tile
        end
    end
    local result = OverlapGroup:new{ dimen = dimen, plank, group }
    return result
end

-- drainRenderStats() -> n, ms since the last drain: how many slot renders
-- (cache misses) a paint pass cost. Logged by the widget's perf lines.
function SpineShelf.drainRenderStats()
    local n, ms = SpineShelf._renders or 0, SpineShelf._render_ms or 0
    local samples = SpineShelf._samples or 0
    SpineShelf._renders, SpineShelf._render_ms, SpineShelf._samples = 0, 0, 0
    return n, ms, samples
end

SpineShelf._SpineBookSlot = SpineBookSlot  -- for tests

return SpineShelf
