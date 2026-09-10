-- tests/_test_grid_zoom_ladder.lua
-- The zoom ladder on both expanded shelves: what a pinch or a spread does to
-- the density, and the HALF step each carries behind its own whole number --
-- the cover grid's column count, the spine shelf's row pin.
--
-- Rows are not a setting in cover mode, they fall out of the column count,
-- so the ladder is coarse and its steps land differently on every device.
-- Measured on a 1236x1648 panel, the expanded shelf fits 5 rows at 6 columns,
-- 4 at 5, 3 at 4 and 2 at 3 -- and because those boundaries move with the
-- chip bar's height, one reader zooming in from four rows lands on three and
-- another lands on two (the device report this exists for).
--
-- A stored 4.5 means "four columns, one more row than fits", drawn by the
-- same squash that already gives a 2-column expanded shelf two rows. What is
-- asserted here is the LADDER: that each step changes what is drawn, in one
-- direction, without skipping a reachable density.
--
-- The real method bodies are extracted and run under stubs (the same approach
-- as _test_list_row_budget), against a layout model taken from the device
-- measurement above rather than from the widget's own arithmetic.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(name, args)
    local pat = "\nfunction BookshelfWidget:" .. name
        .. "%(" .. (args or "") .. "%)\n(.-)\nend\n"
    local body = src:match(pat)
    assert(body, "could not find BookshelfWidget:" .. name .. " - renamed?")
    return body
end

local function compile(code, env, chunkname)
    if _G.setfenv then
        local f = assert(_G.loadstring(code, chunkname))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, chunkname, "t", env))
end

-- _halfStepOf is a file local shared by BOTH predicates; their extracted
-- bodies name it, so the harness supplies the real one rather than a
-- re-implementation that could disagree about the clamp.
local halfOfBody = src:match("\nlocal function _halfStepOf%(v, lo, hi%)\n(.-)\nend\n")
assert(halfOfBody, "_halfStepOf is gone or was renamed")
local halfOf = compile("local v, lo, hi = ...\n" .. halfOfBody,
                       { math = math, type = type }, "_halfStepOf")

local COLUMNS_MIN, COLUMNS_MAX = 2, 6

-- Rows that FIT at natural cover height, measured on the device. The widget
-- computes this from screen primitives; restating the measurement keeps the
-- test about the ladder rather than about the arithmetic (_test_tall_screen
-- covers that).
local NATURAL_ROWS = { [6] = 5, [5] = 4, [4] = 3, [3] = 2, [2] = 1 }

-- _gridColsHalfStep reads `self` off the method call, so give the extracted
-- body a `self` the same way the widget would.
local halfStepBody = bodyOf("_gridColsHalfStep")
local function halfStep(self, store)
    local env = {
        BookshelfSettings = { read = function(k) return store[k] end },
        COLUMNS_MIN = COLUMNS_MIN, COLUMNS_MAX = COLUMNS_MAX,
        _halfStepOf = halfOf, math = math, type = type,
    }
    return compile("local self = ...\n" .. halfStepBody, env, "half")(self)
end

-- A fixture that models the shelf: the stored value decides the columns (the
-- fraction floored away, exactly as _gridCols does) and the rows, with the
-- half buying one more row than fits. The collapsed guarantee -- always at
-- least one row more than the collapsed shelf -- is modeled too, because it
-- is what makes the bottom of the ladder flat.
local function shelf(opts)
    opts = opts or {}
    local store = { bookshelf_columns = opts.columns }
    local s = {
        _expanded = opts.expanded ~= false,
        _nav_dirty = false,
        draft_rebuilds = 0,
    }
    local Settings = {
        read = function(key) return store[key] end,
        saveDeferred = function(key, v) store[key] = v end,
    }
    function s:_isListMode()  return opts.list  == true end
    function s:_isSpineMode() return opts.spine == true end
    function s:_nCols() return 4 end
    function s:_clearDpadFocus() end
    function s:_draftRebuild() self.draft_rebuilds = self.draft_rebuilds + 1 end
    function s:_scheduleNavFlush() end
    function s:_scheduleCoverSettle() end
    function s:_gridCols()
        local v = store.bookshelf_columns or 4
        return math.max(COLUMNS_MIN, math.min(COLUMNS_MAX, math.floor(v)))
    end
    function s:_gridColsHalfStep()
        return halfStep(self, store) or false
    end
    function s:_nShelves()
        local cols = self:_gridCols()
        local fits = NATURAL_ROWS[cols] or 1
        local half = self:_gridColsHalfStep() and 1 or 0
        if not self._expanded then return math.max(1, math.floor(fits / 2)) end
        -- max(fits + half, collapsed + 1): the widget's own expanded rule.
        local collapsed = math.max(1, math.floor(fits / 2))
        return math.max(fits + half, collapsed + 1)
    end
    s._store    = store
    s._settings = Settings
    return s
end

t.test("the half is only read on the expanded cover shelf", function()
    local store = { bookshelf_columns = 4.5 }
    local cover_expanded = { _expanded = true,
        _isListMode = function() return false end,
        _isSpineMode = function() return false end }
    eq(halfStep(cover_expanded, store), true, "expanded cover grid")

    local collapsed = { _expanded = false,
        _isListMode = function() return false end,
        _isSpineMode = function() return false end }
    -- Collapsed, the extra row would come out of the hero, which
    -- SHELF_PACK_FLOOR exists to prevent.
    assert(not halfStep(collapsed, store), "collapsed must ignore the half")

    for _, mode in ipairs({ "list", "spine" }) do
        local m = { _expanded = true,
            _isListMode  = function() return mode == "list" end,
            _isSpineMode = function() return mode == "spine" end }
        assert(not halfStep(m, store), mode .. " mode has its own density knob")
    end
end)

t.test("a whole column count carries no half", function()
    local self_ = { _expanded = true,
        _isListMode = function() return false end,
        _isSpineMode = function() return false end }
    for _, v in ipairs({ 2, 3, 4, 5, 6 }) do
        assert(not halfStep(self_, { bookshelf_columns = v }),
            tostring(v) .. " should be a whole step")
    end
    assert(not halfStep(self_, {}), "an unset count is not a half step")
    assert(not halfStep(self_, { bookshelf_columns = "4.5" }),
        "a non-number must not be treated as a half")
end)

t.test("a half outside the clamp buys nothing", function()
    -- Past the maximum the column count is clamped back, so the extra row
    -- would shrink the covers for no gain.
    local self_ = { _expanded = true,
        _isListMode = function() return false end,
        _isSpineMode = function() return false end }
    assert(not halfStep(self_, { bookshelf_columns = 6.5 }), "above the max")
    assert(not halfStep(self_, { bookshelf_columns = 1.5 }), "below the min")
    assert(halfStep(self_, { bookshelf_columns = 2.5 }),
        "the lowest reachable half is inside the clamp")
end)

-- ── the ladder ─────────────────────────────────────────────────────────────

local nudgeBody = bodyOf("_nudgeColumns", "delta")

local function nudge(s, delta)
    local env = {
        BookshelfSettings = s._settings,
        COLUMNS_MIN = COLUMNS_MIN, COLUMNS_MAX = COLUMNS_MAX,
        UIManager = { setDirty = function() end },
        SpineWidget = { draftWasLossless = function() return false end },
        math = math, type = type,
    }
    return compile("local self, delta = ...\n" .. nudgeBody, env, "nudge")(s, delta)
end

local function ladder(s, delta, steps)
    local out = {}
    for _i = 1, steps do
        out[#out + 1] = { stored = s._store.bookshelf_columns,
                          cols = s:_gridCols(), rows = s:_nShelves() }
        nudge(s, delta)
    end
    return out
end

t.test("zooming in steps through every reachable density", function()
    -- Spread = zoom in = bigger covers = fewer books, and the measured
    -- ladder on the device (30, 25, 20, 16, 12, 9, 6, 4) has no gap in it.
    local s = shelf({ columns = 6, expanded = true })
    local seen = ladder(s, -1, 8)
    local books = {}
    for i, step in ipairs(seen) do
        books[i] = step.cols * step.rows
    end
    eq(table.concat(books, ","), "30,25,20,16,12,9,6,4", "the density ladder")
    -- Strictly decreasing: a zoom step must never make the grid denser.
    for i = 2, #books do
        assert(books[i] < books[i - 1], string.format(
            "step %d went from %d books to %d", i, books[i - 1], books[i]))
    end
end)

t.test("zooming out is the same ladder in reverse", function()
    local s = shelf({ columns = 2, expanded = true })
    local seen = ladder(s, 1, 8)
    local books = {}
    for i, step in ipairs(seen) do books[i] = step.cols * step.rows end
    for i = 2, #books do
        assert(books[i] > books[i - 1], string.format(
            "step %d went from %d books to %d", i, books[i - 1], books[i]))
    end
    eq(books[#books], 30, "reaches the densest grid")
end)

t.test("no step draws the same shelf twice", function()
    -- The bottom of the ladder is where this bites: the "always one more row
    -- than collapsed" guarantee already forces the row a half step would buy,
    -- so 2.5 columns and 2 draw the same grid. A pinch that changes nothing
    -- reads as a dropped gesture, so the handler steps again.
    local s = shelf({ columns = 3, expanded = true })
    local before = { cols = s:_gridCols(), rows = s:_nShelves() }
    nudge(s, -1)   -- 3 -> 2.5, which draws 2x2 ...
    local mid = { cols = s:_gridCols(), rows = s:_nShelves() }
    assert(mid.cols ~= before.cols or mid.rows ~= before.rows,
        "the first step must change the grid")
    -- ... and stepping again from there has nowhere left to go, so the
    -- gesture is consumed without a change rather than looping.
    nudge(s, -1)
    eq(s:_gridCols(), COLUMNS_MIN, "clamped at the biggest covers")
end)

t.test("collapsed, the pinch keeps whole columns", function()
    local s = shelf({ columns = 5, expanded = false })
    nudge(s, -1)
    eq(s._store.bookshelf_columns, 4, "one whole column")
    nudge(s, 1)
    eq(s._store.bookshelf_columns, 5, "and back")
end)

t.test("a half from an expanded session normalises when collapsed", function()
    -- Otherwise a collapsed pinch would leave 4.5 -> 3.5 and the reader would
    -- never get back to whole columns without opening the dialog.
    local s = shelf({ columns = 4.5, expanded = false })
    nudge(s, -1)
    eq(s._store.bookshelf_columns, 3, "floored first, then stepped")
end)

t.test("the ladder is clamped at both ends", function()
    local s = shelf({ columns = 6, expanded = true })
    nudge(s, 1)
    eq(s._store.bookshelf_columns, 6, "cannot go denser than the maximum")
    local s2 = shelf({ columns = 2, expanded = true })
    nudge(s2, -1)
    eq(s2._store.bookshelf_columns, 2, "cannot go bigger than the minimum")
end)

t.test("every step asks for a repaint", function()
    -- The value is written with saveDeferred and the shelf redrawn from the
    -- draft; a step that saved without rebuilding would look like a dead
    -- gesture until the next chip switch.
    local s = shelf({ columns = 5, expanded = true })
    nudge(s, -1)
    eq(s.draft_rebuilds, 1, "one draft rebuild per step")
    assert(s._nav_dirty, "the deferred write must be flagged for the nav flush")
end)

-- ── the spine shelf ────────────────────────────────────────────────────────
--
-- Its expanded row count is NOT the pin. The pin sets the collapsed shelf
-- height and expanding fills the freed space with more rows at that height,
-- so the expanded count runs at roughly twice the pin -- measured on a
-- 1236x1648 panel, pins of 1, 2, 3 and 4 give 2, 3, 5 and 7 rows.
--
-- So the two states keep two numbers. Zooming the expanded shelf must not
-- write the pin, or collapsing stops bringing back the shelf the reader set
-- up there. The rule, from the device request: two rows collapsed, four
-- expanded, zoom to three, and collapsing still gives two.

local DERIVED_ROWS = { [1] = 2, [2] = 3, [3] = 5, [4] = 7, [5] = 8, [6] = 8 }

local spineNudgeBody = bodyOf("_nudgeSpineRows", "delta")
local spineExpandedBody = bodyOf("_spineExpandedRows")

local function spineShelf(opts)
    opts = opts or {}
    local store = { spine_rows = opts.pin,
                    spine_rows_expanded = opts.expanded_pin }
    local s = { _expanded = opts.expanded ~= false, _nav_dirty = false,
                rebuilds = 0, writes = {} }
    function s:_isSpineMode() return opts.covers ~= true end
    function s:_chipListValue(key) return store[key] end
    function s:_setChipDensity(key, v)
        store[key] = v
        self.writes[#self.writes + 1] = key
    end
    function s:_baseShelves()
        return math.max(1, math.min(6, math.floor(store.spine_rows or 1)))
    end
    function s:_spineExpandedRows()
        return compile("local self = ...\n" .. spineExpandedBody,
            { tonumber = tonumber }, "spineExpanded")(self)
    end
    function s:_nShelves()
        local base = self:_baseShelves()
        if not self._expanded then return base end
        local n = self:_spineExpandedRows() or DERIVED_ROWS[base] or 2
        return math.max(base + 1, math.min(math.floor(n), 8))
    end
    function s:_scheduleNavFlush() end
    function s:_clearDpadFocus() end
    function s:_rebuild() self.rebuilds = self.rebuilds + 1 end
    s._store = store
    return s
end

local function spineNudge(s, delta)
    return compile("local self, delta = ...\n" .. spineNudgeBody,
        { UIManager = { setDirty = function() end },
          math = math, tonumber = tonumber, pcall = pcall }, "spineNudge")(s, delta)
end

t.test("zooming the expanded shelf leaves the collapsed pin alone", function()
    local s = spineShelf({ pin = 3 })
    eq(s:_nShelves(), 5, "the derived expanded fill")
    spineNudge(s, -1)
    eq(s:_nShelves(), 4, "one row fewer")
    eq(s._store.spine_rows, 3, "the collapsed pin must not move")
    eq(s._store.spine_rows_expanded, 4, "the expanded count is what moved")
    eq(table.concat(s.writes, ","), "spine_rows_expanded", "only one setting written")
end)

t.test("collapse and expand come back to what each state was set to", function()
    -- The device request, verbatim: three rows collapsed, five expanded,
    -- zoom to four, collapse gives three again, expanding gives four.
    local s = spineShelf({ pin = 3 })
    eq(s:_nShelves(), 5, "expanded")
    spineNudge(s, -1)
    eq(s:_nShelves(), 4, "zoomed")
    s._expanded = false
    eq(s:_nShelves(), 3, "collapsing returns the collapsed shelf")
    s._expanded = true
    eq(s:_nShelves(), 4, "expanding returns the zoomed shelf")
end)

t.test("every expanded row count is reachable", function()
    -- Whole pins alone gave 2, 3, 5, 7: four and six were unreachable, which
    -- is what "4 rows jumps to 2" was.
    local s = spineShelf({ pin = 3 })
    local rows = {}
    for _i = 1, 6 do
        rows[#rows + 1] = s:_nShelves()
        spineNudge(s, -1)
    end
    eq(table.concat(rows, ","), "5,4,4,4,4,4", "clamped at one more than collapsed")
    local up = spineShelf({ pin = 3 })
    local out = {}
    for _i = 1, 5 do
        out[#out + 1] = up:_nShelves()
        spineNudge(up, 1)
    end
    eq(table.concat(out, ","), "5,6,7,8,8", "and up to eight")
end)

t.test("the expanded count keeps the one-more-row-than-collapsed guarantee", function()
    -- Set deliberately low, then read back: expanding must still reveal more
    -- than collapsing did, which is what the swipe-up promises.
    local s = spineShelf({ pin = 4, expanded_pin = 2 })
    eq(s:_nShelves(), 5, "clamped up to base + 1")
    -- And a remembered count survives the pin changing under it rather than
    -- needing to be cleared.
    s._store.spine_rows = 2
    eq(s:_nShelves(), 3, "still one more than the new collapsed count")
end)

t.test("collapsed, the pinch still moves the pin", function()
    local s = spineShelf({ pin = 3, expanded = false })
    spineNudge(s, -1)
    eq(s._store.spine_rows, 2, "the collapsed shelf's own setting")
    eq(s._store.spine_rows_expanded, nil, "and not the expanded one")
end)

t.test("the first expanded zoom starts from what is on screen", function()
    -- Not from the pin: the reader is looking at the derived fill, and a
    -- first zoom that jumped somewhere else would read as a glitch.
    local s = spineShelf({ pin = 2 })
    eq(s:_nShelves(), 3, "derived fill for a pin of 2")
    spineNudge(s, 1)
    eq(s._store.spine_rows_expanded, 4, "stepped from 3, not from the pin")
end)

t.test("both ends are clamped", function()
    local s = spineShelf({ pin = 1 })
    for _i = 1, 4 do spineNudge(s, -1) end
    eq(s:_nShelves(), 2, "never fewer than one more than collapsed")
    local s2 = spineShelf({ pin = 6 })
    for _i = 1, 6 do spineNudge(s2, 1) end
    eq(s2:_nShelves(), 8, "never more than eight")
end)

-- ── wiring ─────────────────────────────────────────────────────────────────

t.test("the expanded row count pays for the half", function()
    -- The functional tests above model _nShelves; this is the assertion that
    -- the widget's own expanded branch asks for the extra row. Without it the
    -- half would be stored, reported by the predicate, and ignored.
    local body = src:match("\nfunction BookshelfWidget:_nShelves%(%)\n(.-)\nend\n")
    assert(body, "_nShelves is gone or was renamed")
    assert(body:match("_gridColsHalfStep"),
        "the expanded cover branch must add the half step's row")
    assert(body:match("_maxRows%(%)%s*%+%s*half")
            or body:match("half%s*%+%s*self:_maxRows%(%)"),
        "the extra row belongs on the natural fit, not on the collapsed count")
end)

t.test("the expanded spine count is read by the row count", function()
    local body = src:match("\nfunction BookshelfWidget:_nShelves%(%)\n(.-)\nend\n")
    assert(body:match("_spineExpandedRows"),
        "the expanded spine branch must consult the reader's own count")
end)

t.test("the expanded zoom writes the expanded key, never the pin", function()
    -- The whole point: a body that wrote spine_rows while expanded would put
    -- the collapsed shelf back to one row, which is what this replaced.
    local body = src:match("\nfunction BookshelfWidget:_nudgeSpineRows%(delta%)\n(.-)\nend\n")
    assert(body, "_nudgeSpineRows is gone or was renamed")
    assert(body:match("spine_rows_expanded"), "must know the expanded key")
    assert(body:match("self%._expanded"),
        "must choose the key by which shelf is on screen")
end)

t.test("nothing else has to know about the fraction", function()
    -- _gridCols floors, which is what keeps a fractional setting invisible to
    -- the rest of the plugin (the Columns/Rows editor reads through it).
    local body = src:match("\nfunction BookshelfWidget:_gridCols%(%)\n(.-)\nend\n")
    assert(body, "_gridCols is gone or was renamed")
    assert(body:match("math%.floor%(cols%)"),
        "_gridCols must floor the stored count, or a half would reach the layout")
end)

t.done()
