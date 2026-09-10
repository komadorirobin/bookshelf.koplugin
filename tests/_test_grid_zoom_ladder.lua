-- tests/_test_grid_zoom_ladder.lua
-- The cover grid's zoom ladder: what a pinch or a spread does to the density,
-- and the HALF step the expanded shelf carries behind the column count.
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
        math = math, type = type,
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

t.test("nothing else has to know about the fraction", function()
    -- _gridCols floors, which is what keeps a fractional setting invisible to
    -- the rest of the plugin (the Columns/Rows editor reads through it).
    local body = src:match("\nfunction BookshelfWidget:_gridCols%(%)\n(.-)\nend\n")
    assert(body, "_gridCols is gone or was renamed")
    assert(body:match("math%.floor%(cols%)"),
        "_gridCols must floor the stored count, or a half would reach the layout")
end)

t.done()
