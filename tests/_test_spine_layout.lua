-- tests/_test_spine_layout.lua
-- lib/bookshelf_spine_layout.lua: the spine view's pure geometry.
--
-- Pins the three mappings (pages->width, aspect->height, favourite
-- face-out width) at their clamps and midpoints, and the greedy
-- variable-width pagination -- the part a device screenshot cannot
-- check at the boundaries (unknown pages, absurd aspect, one book
-- wider than the whole shelf).
--
-- Usage (from plugin root): lua tests/_test_spine_layout.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H  = dofile("tests/_helpers.lua")
local t  = H.runner()
local eq = H.eq

local SL = require("lib/bookshelf_spine_layout")

-- ── width from page count ───────────────────────────────────────────────

t.test("width: unknown pages -> the DEFAULT_PAGES width, not the minimum", function()
    local dflt = SL.spineWidthDp(SL.DEFAULT_PAGES)
    eq(SL.spineWidthDp(nil), dflt)
    eq(SL.spineWidthDp(0), dflt)
    eq(SL.spineWidthDp(-5), dflt)
    eq(SL.spineWidthDp("not a number"), dflt)
    assert(dflt > SL.MIN_W_DP, "default width must sit above the minimum")
end)

t.test("width: clamps at both ends", function()
    eq(SL.spineWidthDp(1), SL.MIN_W_DP)
    eq(SL.spineWidthDp(SL.MIN_PAGES), SL.MIN_W_DP)
    eq(SL.spineWidthDp(SL.MAX_PAGES), SL.MAX_W_DP)
    eq(SL.spineWidthDp(99999), SL.MAX_W_DP)
end)

t.test("width: monotonic in pages", function()
    local prev = SL.spineWidthDp(SL.MIN_PAGES)
    for pages = SL.MIN_PAGES, SL.MAX_PAGES, 100 do
        local w = SL.spineWidthDp(pages)
        assert(w >= prev, "width shrank as pages grew at " .. pages)
        prev = w
    end
end)

-- ── height from aspect ──────────────────────────────────────────────────

t.test("height: reference aspect nearly fills the row", function()
    eq(SL.spineHeight(1000, SL.REF_ASPECT), 980)  -- TOP_FRAC = 0.98
end)

t.test("height: taller-than-reference clamps to TOP_FRAC, never over the row", function()
    eq(SL.spineHeight(1000, 5.0), 980)
    assert(SL.spineHeight(100, 5.0) <= 100)
end)

t.test("height: squat covers floor at MIN_FRAC", function()
    eq(SL.spineHeight(1000, 0.5), 620)  -- MIN_FRAC = 0.62
end)

t.test("height: unknown aspect uses the default, and never returns 0", function()
    eq(SL.spineHeight(1000, nil), SL.spineHeight(1000, SL.DEFAULT_ASPECT))
    assert(SL.spineHeight(1, 1.5) >= 1)
end)

-- ── favourite face-out width ────────────────────────────────────────────

t.test("face-out: width is spine height over aspect", function()
    eq(SL.faceOutWidth(300, 1.5), 200)
    eq(SL.faceOutWidth(300, nil), 200)  -- default aspect 1.5
    assert(SL.faceOutWidth(1, 10) >= 1)
end)

-- ── greedy row fill ─────────────────────────────────────────────────────

t.test("fill: packs greedily and starts a new row when full", function()
    -- shelf 100 wide, gap 2: 40+2+40 = 82 fits, +2+40 would be 124 -> new row
    local rows = SL.fillRows({ 40, 40, 40, 40, 40 }, 100, 2)
    eq(#rows, 3)
    eq(rows[1], { first = 1, last = 2 })
    eq(rows[2], { first = 3, last = 4 })
    eq(rows[3], { first = 5, last = 5 })
end)

t.test("fill: a single book wider than the shelf still gets a row", function()
    local rows = SL.fillRows({ 500, 40 }, 100, 2)
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 1 })
    eq(rows[2], { first = 2, last = 2 })
end)

t.test("fill: empty input -> no rows", function()
    eq(#SL.fillRows({}, 100, 2), 0)
end)

t.test("fill: exact fit is kept on one row", function()
    local rows = SL.fillRows({ 49, 49 }, 100, 2)
    eq(#rows, 1)
    eq(rows[1], { first = 1, last = 2 })
end)

t.test("fill: per-book gaps make a group boundary count against the row", function()
    -- 40+2+40 = 82 fits; book 3 carries a 20 boundary gap: 82+20+40 = 142
    -- -> wraps, where a flat gap of 2 would have kept it (124 > 100 anyway;
    -- use a wider shelf so only the boundary gap forces the wrap).
    local rows = SL.fillRows({ 40, 40, 40 }, 130, { 0, 2, 20 })
    eq(#rows, 2)
    eq(rows[1], { first = 1, last = 2 })
    eq(rows[2], { first = 3, last = 3 })
    -- Same widths with the small gap everywhere DO fit three across.
    eq(#SL.fillRows({ 40, 40, 40 }, 130, { 0, 2, 2 }), 1)
end)

-- ── pagination ──────────────────────────────────────────────────────────

t.test("paginate: groups rows and reports book index bounds", function()
    local rows = SL.fillRows({ 40, 40, 40, 40, 40 }, 100, 2)  -- 3 rows
    local pages = SL.paginate(rows, 2)
    eq(#pages, 2)
    eq(pages[1].first, 1); eq(pages[1].last, 4); eq(#pages[1].rows, 2)
    eq(pages[2].first, 5); eq(pages[2].last, 5); eq(#pages[2].rows, 1)
end)

t.test("paginate: single-row pages give the footer its n-m slice", function()
    local rows = SL.fillRows({ 40, 40, 40 }, 100, 2)  -- {1-2},{3}
    local pages = SL.paginate(rows, 1)
    eq(#pages, 2)
    eq(pages[1].first, 1); eq(pages[1].last, 2)
end)

t.test("paginate: rows_per_page below 1 behaves as 1", function()
    local rows = SL.fillRows({ 40, 40, 40 }, 100, 2)
    eq(#SL.paginate(rows, 0), 2)
end)

t.done()
