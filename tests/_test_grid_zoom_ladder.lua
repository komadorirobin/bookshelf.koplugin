-- tests/_test_grid_zoom_ladder.lua
-- What a pinch or a spread does, in each of the three shelf modes.
--
-- The rule the two row-count modes follow: THE EXPANDED SHELF IS THE
-- COLLAPSED ONE PLUS AN OFFSET. Zooming the expanded shelf moves the offset,
-- never the collapsed setting, so collapsing brings back what was set up
-- there and expanding brings back what was zoomed to -- and because what is
-- stored is a DISTANCE, changing the collapsed shelf still moves the
-- expanded one with it. Stated by the maintainer as: two rows collapsed,
-- expand to four, zoom to three; collapsing gives two again and expanding
-- gives three back, but the two must stay linked rather than divorced.
--
-- Cover mode is deliberately NOT in that club. Its pinch is the cover SIZE
-- knob and moves the column count; rows fall out of the width. Reaching an
-- in-between row count there would mean squashing covers and spreading the
-- slack, which was tried and rejected: "5x5 looks wrong for covers".
--
-- The real method bodies are extracted and run under stubs (the same approach
-- as _test_list_row_budget), against layout models measured on a 1236x1648
-- panel rather than against the widget's own arithmetic.

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

-- ── cover mode: whole columns, both states ─────────────────────────────────

local COLUMNS_MIN, COLUMNS_MAX = 2, 6
local nudgeColsBody = bodyOf("_nudgeColumns", "delta")

local function grid(opts)
    opts = opts or {}
    local store = { bookshelf_columns = opts.columns }
    local s = { _expanded = opts.expanded ~= false, _nav_dirty = false,
                drafts = 0 }
    local Settings = {
        read = function(k) return store[k] end,
        saveDeferred = function(k, v) store[k] = v end,
    }
    function s:_isListMode() return false end
    function s:_isSpineMode() return false end
    function s:_nCols() return 4 end
    function s:_clearDpadFocus() end
    function s:_draftRebuild() self.drafts = self.drafts + 1 end
    function s:_scheduleNavFlush() end
    function s:_scheduleCoverSettle() end
    s._store, s._settings = store, Settings
    return s
end

local function nudgeCols(s, delta)
    return compile("local self, delta = ...\n" .. nudgeColsBody, {
        BookshelfSettings = s._settings,
        COLUMNS_MIN = COLUMNS_MIN, COLUMNS_MAX = COLUMNS_MAX,
        UIManager = { setDirty = function() end },
        SpineWidget = { draftWasLossless = function() return false end },
        math = math, type = type,
    }, "nudgeCols")(s, delta)
end

t.test("the cover pinch moves whole columns, expanded or not", function()
    for _, expanded in ipairs({ true, false }) do
        local s = grid({ columns = 5, expanded = expanded })
        nudgeCols(s, -1)
        eq(s._store.bookshelf_columns, 4,
            "expanded=" .. tostring(expanded) .. ": one whole column")
        nudgeCols(s, 1)
        eq(s._store.bookshelf_columns, 5, "and back")
    end
end)

t.test("the cover count never picks up a fraction", function()
    -- A half column would have to be paid for by squashing the covers and
    -- spreading the slack. Tried, rejected: covers keep a whole-column ladder.
    local s = grid({ columns = 5 })
    for _i = 1, 4 do nudgeCols(s, -1) end
    local v = s._store.bookshelf_columns
    eq(v, math.floor(v), "the stored count must stay a whole number")
    eq(v, COLUMNS_MIN, "and walk down to the clamp")
end)

t.test("the cover ladder is clamped at both ends", function()
    local s = grid({ columns = 6 })
    nudgeCols(s, 1)
    eq(s._store.bookshelf_columns, 6, "cannot go denser than the maximum")
    local s2 = grid({ columns = 2 })
    nudgeCols(s2, -1)
    eq(s2._store.bookshelf_columns, 2, "cannot go bigger than the minimum")
end)

t.test("every cover step asks for a repaint", function()
    local s = grid({ columns = 5 })
    nudgeCols(s, -1)
    eq(s.drafts, 1, "one draft rebuild per step")
    assert(s._nav_dirty, "the deferred write must be flagged for the nav flush")
end)

-- ── spine mode ─────────────────────────────────────────────────────────────
--
-- ONE rule: the collapsed count is the setting, and expanding fills the freed
-- space with more rows AT THE SAME HEIGHT, so a swipe up reveals more books
-- without resizing anything. Zooming the EXPANDED shelf picks its count
-- directly, and the collapsed count follows only where it has to.
--
-- Measured fills on a 1236x1648 panel: a collapsed shelf of 1, 2, 3, 4 rows
-- expands to 2, 4, 6, 8.

local FILL = { [1] = 2, [2] = 4, [3] = 6, [4] = 8, [5] = 8, [6] = 8 }

local spineNudgeBody     = bodyOf("_nudgeSpineRows", "delta")
local spineExpandedBody  = bodyOf("_spineExpandedRows")
local spineCollapsedBody = bodyOf("_spineCollapsedFor", "m")

local function spineShelf(opts)
    opts = opts or {}
    local store = { spine_rows = opts.pin,
                    spine_rows_expanded = opts.expanded }
    local s = { _expanded = opts.collapsed ~= true, _nav_dirty = false,
                rebuilds = 0, writes = {} }
    function s:_isSpineMode() return true end
    function s:_chipListValue(key) return store[key] end
    function s:_setChipDensity(key, v)
        store[key] = v
        self.writes[#self.writes + 1] = key .. "=" .. tostring(v)
    end
    function s:_baseShelves()
        return math.max(1, math.min(6, math.floor(store.spine_rows or 1)))
    end
    function s:_spineFillFor(base) return FILL[base] or 8 end
    function s:_spineExpandedRows()
        return compile("local self = ...\n" .. spineExpandedBody,
            { tonumber = tonumber, math = math }, "spineExpanded")(self)
    end
    function s:_spineCollapsedFor(m)
        return compile("local self, m = ...\n" .. spineCollapsedBody,
            { math = math }, "spineCollapsedFor")(self, m)
    end
    function s:_nShelves()
        if not self._expanded then return self:_baseShelves() end
        return self:_spineExpandedRows() or self:_spineFillFor(self:_baseShelves())
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

t.test("expanding fills at the collapsed shelf's own height", function()
    -- The default, and the reason the swipe up does not resize anything: the
    -- expanded count is whatever fits at the height the collapsed shelf uses.
    for pin = 1, 4 do
        local s = spineShelf({ pin = pin })
        eq(s:_nShelves(), FILL[pin], "pin " .. pin)
        s._expanded = false
        eq(s:_nShelves(), pin, "collapsed, pin " .. pin)
    end
end)

t.test("nudging the expanded shelf from 4 rows to 3 leaves the collapsed shelf at 2", function()
    -- The maintainer's own example, verbatim.
    local s = spineShelf({ pin = 2 })
    eq(s:_nShelves(), 4, "two rows collapsed expands to four")
    spineNudge(s, -1)
    eq(s:_nShelves(), 3, "zoomed to three")
    eq(s._store.spine_rows, 2, "and the collapsed shelf is still two")
    s._expanded = false
    eq(s:_nShelves(), 2, "which is what collapsing shows")
end)

t.test("only sizing the full shelf to 2 rows takes the collapsed shelf to 1", function()
    local s = spineShelf({ pin = 2 })
    spineNudge(s, -1)   -- 4 -> 3
    spineNudge(s, -1)   -- 3 -> 2
    eq(s:_nShelves(), 2, "zoomed to two")
    eq(s._store.spine_rows, 1, "now the collapsed shelf drops to one")
    s._expanded = false
    eq(s:_nShelves(), 1, "which is what collapsing shows")
end)

t.test("the zoomed count comes back on the next expand", function()
    local s = spineShelf({ pin = 2 })
    spineNudge(s, -1)
    s._expanded = false
    eq(s:_nShelves(), 2, "collapsed")
    s._expanded = true
    eq(s:_nShelves(), 3, "expanded again")
end)

t.test("setting the collapsed shelf puts the expanded one back to filling", function()
    -- The reader has just said what shelf they want; a count zoomed against
    -- the old one no longer describes it.
    local s = spineShelf({ pin = 2 })
    spineNudge(s, -1)
    eq(s._store.spine_rows_expanded, 3, "zoomed")
    s._expanded = false
    spineNudge(s, 1)
    eq(s._store.spine_rows, 3, "the collapsed shelf moved")
    eq(s._store.spine_rows_expanded, nil, "and the zoom was cleared")
    s._expanded = true
    eq(s:_nShelves(), FILL[3], "so the expanded shelf fills again")
end)

t.test("expanding always shows more rows than collapsing", function()
    -- Not a rule on top: the collapsed count that goes with an expanded count
    -- is never as large as it, so it falls out of the mapping.
    for pin = 1, 4 do
        local s = spineShelf({ pin = pin })
        for _i = 1, 8 do
            assert(s:_nShelves() > s:_baseShelves(), string.format(
                "pin %d: expanded %d is not more than collapsed %d",
                pin, s:_nShelves(), s:_baseShelves()))
            spineNudge(s, -1)
        end
    end
end)

t.test("a stale zoom is ignored rather than shrinking the expanded shelf", function()
    -- The shelf-style dialog writes the collapsed count without going through
    -- the pinch, so a zoom from before can be left describing a shelf that no
    -- longer exists.
    local s = spineShelf({ pin = 4, expanded = 2 })
    eq(s:_nShelves(), FILL[4], "the stale count is dropped for the fill")
end)

t.test("the expanded ladder reaches every count down to two", function()
    local s = spineShelf({ pin = 3 })
    local rows = {}
    for _i = 1, 6 do
        rows[#rows + 1] = s:_nShelves()
        spineNudge(s, -1)
    end
    eq(table.concat(rows, ","), "6,5,4,3,2,2", "one row at a time, floored at two")
end)

-- ── list mode: the same rule ───────────────────────────────────────────────
--
-- Its bands are closer together than the spine shelf's, so the mapping bites
-- at the bottom: a one-row collapsed list can fill the expanded band with one
-- row, and the collapsed shelf has to give way for two to be reachable.

local ListGeom = require("lib/bookshelf_list_geom")
local listNudgeBody     = bodyOf("_nudgeListRows", "delta")
local listExpandedBody  = bodyOf("_listRowsExpanded")
local listCollapsedBody = bodyOf("_listCollapsedFor", "m")

local COLLAPSED_BAND, EXPANDED_BAND = 900, 1500
local NATURAL_ROW, MIN_ROW = 300, 100

local function listShelf(opts)
    opts = opts or {}
    local store = { list_rows = opts.rows, list_rows_expanded = opts.expanded }
    local s = { _expanded = opts.collapsed ~= true, _nav_dirty = false,
                drafts = 0, writes = {} }
    function s:_isListMode() return true end
    function s:_chipListValue(key) return store[key] end
    function s:_setChipDensity(key, v)
        store[key] = v
        self.writes[#self.writes + 1] = key .. "=" .. tostring(v)
    end
    function s:_setChipListRows(n) self:_setChipDensity("list_rows", n) end
    function s:_listBand(expanded)
        return { band = expanded and EXPANDED_BAND or COLLAPSED_BAND,
                 min_edge_pad = 0, base_top_pad = 0 }
    end
    function s:_listRowGap() return 0 end
    function s:_listMinRowHeight() return MIN_ROW end
    function s:_listNaturalRowHeight() return NATURAL_ROW end
    function s:_listSolveRowHeight(b, rows)
        return math.max(MIN_ROW, math.floor(b.band / rows))
    end
    function s:_listRows(max_rows)
        local n = store.list_rows
        if type(n) ~= "number" then return nil end
        return math.max(1, math.min(max_rows or n, math.floor(n)))
    end
    function s:_listCollapsedRowsNow()
        return self:_listRows(math.floor(COLLAPSED_BAND / MIN_ROW))
               or ListGeom.rowsThatFit(COLLAPSED_BAND, NATURAL_ROW, 0)
    end
    function s:_listFillFor(n)
        -- The same floor the real one carries: expanding reveals more rows.
        return math.max(n + 1, ListGeom.rowsThatFit(EXPANDED_BAND,
            self:_listSolveRowHeight({ band = COLLAPSED_BAND }, n), 0))
    end
    function s:_listExpandedCount()
        return self:_listRowsExpanded()
               or self:_listFillFor(self:_listCollapsedRowsNow())
    end
    function s:_listRowsExpanded()
        return compile("local self = ...\n" .. listExpandedBody,
            { tonumber = tonumber, math = math }, "listExpanded")(self)
    end
    function s:_listCollapsedFor(m)
        return compile("local self, m = ...\n" .. listCollapsedBody,
            { require = function() return ListGeom end, math = math },
            "listCollapsedFor")(self, m)
    end
    function s:_nShelves()
        if not self._expanded then return self:_listCollapsedRowsNow() end
        return self:_listExpandedCount()
    end
    function s:_clearDpadFocus() end
    function s:_draftRebuild() self.drafts = self.drafts + 1 end
    function s:_scheduleNavFlush() end
    function s:_scheduleCoverSettle() end
    s._store = store
    return s
end

local function listNudge(s, delta)
    return compile("local self, delta = ...\n" .. listNudgeBody, {
        require = function(name)
            assert(name == "lib/bookshelf_list_geom", "unexpected require: " .. name)
            return ListGeom
        end,
        UIManager = { setDirty = function() end },
        SpineWidget = { draftWasLossless = function() return false end },
        math = math, type = type,
    }, "listNudge")(s, delta)
end

t.test("the expanded list fills at the collapsed list's own height", function()
    local s = listShelf({ rows = 3 })
    eq(s:_nShelves(), 5, "three rows of 300 fill 1500 with five")
    s._expanded = false
    eq(s:_nShelves(), 3, "collapsed is still three")
end)

t.test("zooming the expanded list moves the collapsed one only where it must", function()
    local s = listShelf({ rows = 3 })
    listNudge(s, -1)
    eq(s:_nShelves(), 4, "zoomed to four")
    eq(s._store.list_rows, 3, "the collapsed list has not moved")
    listNudge(s, -1)
    eq(s:_nShelves(), 3, "zoomed to three")
    eq(s._store.list_rows, 2, "now it has")
end)

t.test("the zoomed list count comes back on the next expand", function()
    local s = listShelf({ rows = 3 })
    listNudge(s, -1)
    local zoomed = s:_nShelves()
    s._expanded = false
    local collapsed = s:_nShelves()
    s._expanded = true
    eq(s:_nShelves(), zoomed, "expanding returns the zoomed list")
    assert(collapsed < zoomed, "and it is still more rows than collapsing")
end)

t.test("setting the collapsed list puts the expanded one back to filling", function()
    local s = listShelf({ rows = 3 })
    listNudge(s, -1)
    s._expanded = false
    listNudge(s, 1)
    eq(s._store.list_rows_expanded, nil, "the zoom was cleared")
end)

t.test("the expanded list always shows more rows than the collapsed one", function()
    for rows = 1, 4 do
        local s = listShelf({ rows = rows })
        for _i = 1, 8 do
            assert(s:_nShelves() > s:_listCollapsedRowsNow(), string.format(
                "rows %d: expanded %d is not more than collapsed %d",
                rows, s:_nShelves(), s:_listCollapsedRowsNow()))
            listNudge(s, -1)
        end
    end
end)

t.test("a stale list zoom is ignored", function()
    local s = listShelf({ rows = 4, expanded = 2 })
    assert(s:_nShelves() > 2, "the stale count is dropped for the fill")
end)

-- ── wiring ─────────────────────────────────────────────────────────────────

t.test("the expanded counts are read where the rows are decided", function()
    local body = src:match("\nfunction BookshelfWidget:_nShelves%(%)\n(.-)\nend\n")
    assert(body, "_nShelves is gone or was renamed")
    assert(body:match("_spineExpandedRows"),
        "the expanded spine branch must consult the count the reader zoomed to")
    assert(body:match("_spineFillFor"),
        "and fall back to the fill at the collapsed height")
    local plan = src:match(
        "\nfunction BookshelfWidget:_listBandPlanUncached%(expanded, hide_chip_bar%)\n(.-)\nend\n")
    assert(plan, "_listBandPlanUncached is gone or was renamed")
    assert(plan:match("_listExpandedCount"),
        "the expanded list plan must take the count the expanded list shows, "
        .. "which is the zoom when there is one and the fill otherwise")
end)

t.test("each nudge writes for the shelf on screen and clears the other", function()
    local want = {
        _nudgeSpineRows = { "spine_rows_expanded", "_spineCollapsedFor" },
        _nudgeListRows  = { "list_rows_expanded",  "_listCollapsedFor"  },
    }
    for name, keys in pairs(want) do
        local body = src:match("\nfunction BookshelfWidget:" .. name
            .. "%(delta%)\n(.-)\nend\n")
        assert(body, name .. " is gone or was renamed")
        assert(body:match("self%._expanded"),
            name .. " must choose by which shelf is on screen")
        for _, k in ipairs(keys) do
            assert(body:match(k), name .. " must reference " .. k)
        end
        assert(body:match("_rows_expanded\", nil%)"),
            name .. " must clear the zoom when the collapsed shelf is set")
    end
end)

t.test("the list row height is solved per state", function()
    local body = src:match(
        "\nfunction BookshelfWidget:_listRowHeight%(expanded%)\n(.-)\nend\n")
    assert(body, "_listRowHeight lost its state argument")
    assert(body:match('"row_h:"'), "the memo key must carry the state")
end)

t.test("cover mode keeps no row count of its own", function()
    -- Its pinch is the cover size knob; rows follow the width. A row pin here
    -- would be the 5x5 layout that was rejected.
    assert(not src:match("cover_rows_expanded"), "covers must not grow a row pin")
    assert(not src:match("_gridColsHalfStep"), "no half step on the column count")
end)

t.done()
