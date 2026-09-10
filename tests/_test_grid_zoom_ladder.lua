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

-- ── spine mode: two states, two numbers ────────────────────────────────────
--
-- Its expanded row count is NOT the pin. The pin sets the collapsed shelf
-- height and expanding fills the freed space with more rows at that height,
-- so the expanded count runs at roughly twice the pin -- measured, pins of 1,
-- 2, 3 and 4 give 2, 3, 5 and 7 rows.

local DERIVED_ROWS = { [1] = 2, [2] = 3, [3] = 5, [4] = 7, [5] = 8, [6] = 8 }

local spineNudgeBody  = bodyOf("_nudgeSpineRows", "delta")
local spineOffsetBody = bodyOf("_spineExpandedOffset")

local function spineShelf(opts)
    opts = opts or {}
    local store = { spine_rows = opts.pin,
                    spine_expanded_offset = opts.offset }
    local s = { _expanded = opts.expanded ~= false, _nav_dirty = false,
                rebuilds = 0, writes = {} }
    function s:_isSpineMode() return true end
    function s:_chipListValue(key) return store[key] end
    function s:_setChipDensity(key, v)
        store[key] = v
        self.writes[#self.writes + 1] = key
    end
    function s:_baseShelves()
        return math.max(1, math.min(6, math.floor(store.spine_rows or 1)))
    end
    -- The measured fill, standing in for the real geometry.
    function s:_spineDerivedRows() return DERIVED_ROWS[self:_baseShelves()] or 2 end
    function s:_spineExpandedOffset()
        return compile("local self = ...\n" .. spineOffsetBody,
            { tonumber = tonumber, math = math }, "spineOffset")(self)
    end
    function s:_nShelves()
        if not self._expanded then return self:_baseShelves() end
        return math.max(1, math.min(8,
            self:_spineDerivedRows() + self:_spineExpandedOffset()))
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

t.test("zooming the expanded spine shelf leaves the pin alone", function()
    local s = spineShelf({ pin = 3 })
    eq(s:_nShelves(), 5, "the derived fill")
    spineNudge(s, -1)
    eq(s:_nShelves(), 4, "one row fewer")
    eq(s._store.spine_rows, 3, "the collapsed pin must not move")
    eq(s._store.spine_expanded_offset, -1, "the distance is what was stored")
    eq(table.concat(s.writes, ","), "spine_expanded_offset", "one setting written")
end)

t.test("collapse and expand return each state to its own shelf", function()
    local s = spineShelf({ pin = 3 })
    spineNudge(s, -1)
    eq(s:_nShelves(), 4, "zoomed")
    s._expanded = false
    eq(s:_nShelves(), 3, "collapsing returns the collapsed shelf")
    s._expanded = true
    eq(s:_nShelves(), 4, "expanding returns the zoomed shelf")
end)

t.test("the expanded shelf still follows the collapsed one", function()
    -- The whole point of storing a distance rather than a second row count:
    -- the two must stay linked, not divorced. Change the collapsed shelf and
    -- the expanded one moves with it, keeping the reader's adjustment.
    local s = spineShelf({ pin = 3 })
    spineNudge(s, -1)
    eq(s:_nShelves(), 4, "fill of 5, one fewer")
    s._expanded = false
    spineNudge(s, 1)                      -- the collapsed shelf gets denser
    eq(s._store.spine_rows, 4, "the pin moved")
    eq(s._store.spine_expanded_offset, -1, "the adjustment is untouched")
    s._expanded = true
    eq(s:_nShelves(), 6, "fill of 7 for the new pin, still one fewer")
end)

t.test("the expanded shelf can be zoomed below the collapsed count", function()
    -- The floor used to be the collapsed pin plus one, which made two rows
    -- unreachable on any shelf pinned to two or more (device report). That
    -- guarantee protects the DEFAULT fill; an adjustment the reader made
    -- themselves is taken as given.
    local s = spineShelf({ pin = 4 })
    local rows = {}
    for _i = 1, 7 do
        rows[#rows + 1] = s:_nShelves()
        spineNudge(s, -1)
    end
    eq(table.concat(rows, ","), "7,6,5,4,3,2,1", "all the way down")
    s._expanded = false
    eq(s:_nShelves(), 4, "and the collapsed shelf is untouched by all of it")
end)

t.test("the collapsed spine pinch still moves the pin", function()
    local s = spineShelf({ pin = 3, expanded = false })
    spineNudge(s, -1)
    eq(s._store.spine_rows, 2, "the collapsed shelf's own setting")
    eq(s._store.spine_expanded_offset, nil, "and not the offset")
end)

t.test("the spine ladder is clamped at both ends", function()
    local s = spineShelf({ pin = 1, offset = -1 })
    spineNudge(s, -1)
    eq(s:_nShelves(), 1, "never fewer than one")
    local s2 = spineShelf({ pin = 6, offset = 4 })
    spineNudge(s2, 1)
    eq(s2:_nShelves(), 8, "never more than eight")
end)

-- ── list mode: the same rule ───────────────────────────────────────────────
--
-- List rows have a height rather than an aspect, so each state solves its own
-- height against its own band and its own count.

local ListGeom = require("lib/bookshelf_list_geom")
local listNudgeBody  = bodyOf("_nudgeListRows", "delta")
local listOffsetBody = bodyOf("_listExpandedOffset")
local listRowsBody   = bodyOf("_listExpandedRows")

local COLLAPSED_BAND, EXPANDED_BAND = 900, 1800
local NATURAL_ROW, MIN_ROW = 200, 50

local function listShelf(opts)
    opts = opts or {}
    local store = { list_rows = opts.rows,
                    list_expanded_offset = opts.offset }
    local s = { _expanded = opts.expanded ~= false, _nav_dirty = false,
                drafts = 0, writes = {} }
    local env = { require = function() return ListGeom end,
                  tonumber = tonumber, math = math }
    function s:_isListMode() return true end
    function s:_chipListValue(key) return store[key] end
    function s:_setChipDensity(key, v)
        store[key] = v
        self.writes[#self.writes + 1] = key
    end
    function s:_listBand(expanded)
        return { band = expanded and EXPANDED_BAND or COLLAPSED_BAND,
                 min_edge_pad = 0, base_top_pad = 0 }
    end
    function s:_listRowGap() return 0 end
    function s:_listMinRowHeight() return MIN_ROW end
    function s:_listNaturalRowHeight() return NATURAL_ROW end
    function s:_listRowHeight(expanded)
        -- The collapsed band divided by the collapsed count, which is what
        -- the expanded fill is measured against.
        local n = self:_listRows(math.floor(COLLAPSED_BAND / MIN_ROW))
        return n and math.floor(COLLAPSED_BAND / n) or NATURAL_ROW
    end
    function s:_listRows(max_rows)
        local n = store.list_rows
        if type(n) ~= "number" then return nil end
        return math.max(1, math.min(max_rows or n, math.floor(n)))
    end
    function s:_listDerivedExpandedRows()
        return ListGeom.rowsThatFit(EXPANDED_BAND, self:_listRowHeight(false), 0)
    end
    function s:_listExpandedOffset()
        return compile("local self = ...\n" .. listOffsetBody, env, "listOffset")(self)
    end
    function s:_listExpandedRows()
        return compile("local self = ...\n" .. listRowsBody, env, "listRows")(self)
    end
    function s:_nShelves()
        if not self._expanded then
            return self:_listRows(math.floor(COLLAPSED_BAND / MIN_ROW))
                   or math.floor(COLLAPSED_BAND / NATURAL_ROW)
        end
        return self:_listExpandedRows() or self:_listDerivedExpandedRows()
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

t.test("zooming the expanded list leaves the collapsed count alone", function()
    local s = listShelf({ rows = 4 })
    local before = s:_nShelves()
    listNudge(s, -1)
    eq(s._store.list_rows, 4, "the collapsed count must not move")
    eq(s._store.list_expanded_offset, -1, "the distance is what was stored")
    eq(s:_nShelves(), before - 1, "one row fewer")
    eq(table.concat(s.writes, ","), "list_expanded_offset", "one setting written")
end)

t.test("collapse and expand return each list state to its own shelf", function()
    local s = listShelf({ rows = 4 })
    listNudge(s, -1)
    listNudge(s, -1)
    local zoomed = s:_nShelves()
    s._expanded = false
    eq(s:_nShelves(), 4, "collapsing returns the collapsed list")
    s._expanded = true
    eq(s:_nShelves(), zoomed, "expanding returns the zoomed list")
end)

t.test("the expanded list still follows the collapsed one", function()
    local s = listShelf({ rows = 4 })
    listNudge(s, -1)
    local zoomed = s:_nShelves()
    s._expanded = false
    listNudge(s, 1)                     -- the collapsed list gets denser
    eq(s._store.list_rows, 5, "the collapsed count moved")
    eq(s._store.list_expanded_offset, -1, "the adjustment is untouched")
    s._expanded = true
    assert(s:_nShelves() > zoomed, string.format(
        "the expanded list should have moved with the collapsed one: %d then %d",
        zoomed, s:_nShelves()))
end)

t.test("the collapsed list pinch still moves the collapsed count", function()
    local s = listShelf({ rows = 4, expanded = false })
    listNudge(s, -1)
    eq(s._store.list_rows, 3, "the collapsed list's own setting")
    eq(s._store.list_expanded_offset, nil, "and not the offset")
end)

t.test("the expanded list is capped by what its band can hold", function()
    local s = listShelf({ rows = 4 })
    for _i = 1, 60 do listNudge(s, 1) end
    local rows = s:_nShelves()
    assert(rows <= math.floor(EXPANDED_BAND / MIN_ROW), string.format(
        "%d rows will not fit at the minimum row height", rows))
    for _i = 1, 80 do listNudge(s, -1) end
    eq(s:_nShelves(), 1, "and never fewer than one")
end)

-- ── wiring ─────────────────────────────────────────────────────────────────

t.test("the expanded row counts are read where the rows are decided", function()
    local body = src:match("\nfunction BookshelfWidget:_nShelves%(%)\n(.-)\nend\n")
    assert(body, "_nShelves is gone or was renamed")
    assert(body:match("_spineExpandedOffset"),
        "the expanded spine branch must add the reader's own adjustment")
    assert(body:match("_spineDerivedRows"),
        "and it must start from the fill the pin gives, so the two stay linked")
    local plan = src:match(
        "\nfunction BookshelfWidget:_listBandPlanUncached%(expanded, hide_chip_bar%)\n(.-)\nend\n")
    assert(plan, "_listBandPlanUncached is gone or was renamed")
    assert(plan:match("_listExpandedRows"),
        "the expanded list plan must consult the reader's own adjustment")
end)

t.test("each nudge writes the key for the shelf on screen", function()
    -- The whole point: a body that wrote the collapsed key while expanded
    -- would put the collapsed shelf somewhere the reader never asked for.
    local want = {
        _nudgeSpineRows = "spine_expanded_offset",
        _nudgeListRows  = "list_expanded_offset",
    }
    for name, key in pairs(want) do
        local body = src:match("\nfunction BookshelfWidget:" .. name
            .. "%(delta%)\n(.-)\nend\n")
        assert(body, name .. " is gone or was renamed")
        assert(body:match(key), name .. " must reference " .. key)
        assert(body:match("self%._expanded"),
            name .. " must choose the key by which shelf is on screen")
    end
end)

t.test("the list row height is solved per state", function()
    -- Two counts mean two heights: the expanded band divided by the expanded
    -- count. A single cached height would hand one state the other's rows.
    local body = src:match(
        "\nfunction BookshelfWidget:_listRowHeight%(expanded%)\n(.-)\nend\n")
    assert(body, "_listRowHeight lost its state argument")
    assert(body:match('"row_h:"'), "the memo key must carry the state")
end)

t.test("cover mode keeps no expanded row count", function()
    -- Its pinch is the cover size knob; rows follow the width. A second
    -- number here would be the 5x5 layout that was rejected.
    assert(not src:match("cover_rows_expanded"), "covers must not grow a row pin")
    assert(not src:match("_gridColsHalfStep"), "the column half step is gone")
end)

t.done()
