-- tests/_test_draft_cache_reflow.lua
-- Whether a draft regrid may reuse the last fetch
-- (BookshelfWidget:_draftCacheServes).
--
-- Usage (from plugin root): lua tests/_test_draft_cache_reflow.lua
--
-- WHAT THIS PINS. A pinch does a DRAFT rebuild: geometry changed, the book set
-- did not, so the library read is skipped and the cached fetch reused. That
-- reasoning holds for sources returning the WHOLE list, which _rebuild slices
-- to whatever the page size now is.
--
-- It does not hold for the window-fetched ones -- Home, folder and group
-- drills, search, OPDS, and every plain chip falling through to
-- Repo.getBySource, so most of them. Those return ONE page, cut to
-- self:_viewSize() at fetch time, plus the total, and _rebuild uses that page
-- verbatim. A pinch that adds rows grows _viewSize(), so the cached page is
-- too short and the new rows render blank -- while the footer's "Page 1 of N"
-- has already halved, because the page COUNT is derived from the new size.
-- Reported against the list shelf, where a zoom-out left two filled rows and
-- most of a screen empty.
--
-- bookshelf_widget.lua is 19k lines and needs the whole KOReader stack to
-- load, so the method is extracted by name and called against a plain table.
-- See _test_widget_body_extraction-style suites for the same technique.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- Pull the function body out of the file and compile it standalone.
local serves
do
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    local body = src:match(
        "\nfunction BookshelfWidget:_draftCacheServes%(cached, view_size%)\n(.-)\nend\n")
    assert(body, "BookshelfWidget:_draftCacheServes is gone or was renamed")
    local chunk = assert(load("return function(self, cached, view_size)\n"
                              .. body .. "\nend"))
    serves = chunk()
end

local function widget(cursor) return { _cursor = cursor or 1 } end

-- ── Whole-list sources ─────────────────────────────────────────────────────

t.test("a whole-list cache serves any page size", function()
    -- No total_hint means the fetch returned everything and _rebuild slices
    -- it, so growing the view just takes a longer slice.
    local cache = { all_items = { 1, 2, 3 } }
    assert(serves(widget(), cache, 12), "a whole-list cache was thrown away")
end)

-- ── Window-fetched sources ─────────────────────────────────────────────────

t.test("a window that already covers the new page is kept", function()
    -- The common case: pinching to FEWER rows. The cached page is longer than
    -- the view now needs, and the extra entries are simply not drawn -- no
    -- reason to pay for a library read.
    local cache = { all_items = {}, total_hint = 96 }
    for i = 1, 12 do cache.all_items[i] = i end
    assert(serves(widget(), cache, 6), "a still-adequate window was refetched")
end)

t.test("a window too short for the new page is refetched", function()
    -- The bug: pinch to MORE rows, the cached page is stuck at the old size,
    -- and every row past its end renders blank.
    local cache = { all_items = {}, total_hint = 96 }
    for i = 1, 6 do cache.all_items[i] = i end
    assert(not serves(widget(), cache, 12),
        "a short window was reused, so the new rows render empty")
end)

t.test("a short LAST page is not a short window", function()
    -- Being short is only wrong when there was more to have. Four books left
    -- out of 96 with the cursor at 93 IS the whole remainder, and refetching
    -- would cost a library read to be handed the same four back.
    local cache = { all_items = { 1, 2, 3, 4 }, total_hint = 96 }
    assert(serves(widget(93), cache, 12), "the last page was needlessly refetched")
end)

t.test("a short page mid-library is still refetched", function()
    -- Same length, same view, but there are books after it.
    local cache = { all_items = { 1, 2, 3, 4 }, total_hint = 96 }
    assert(not serves(widget(40), cache, 12),
        "a mid-library short window was mistaken for the last page")
end)

t.test("an exactly-full window is kept", function()
    -- The boundary that decides between a free regrid and a library read on
    -- every single pinch step.
    local cache = { all_items = {}, total_hint = 96 }
    for i = 1, 12 do cache.all_items[i] = i end
    assert(serves(widget(), cache, 12), "an exactly-sized window was refetched")
end)

-- ── No cache at all ────────────────────────────────────────────────────────

t.test("a missing or empty cache never serves", function()
    assert(not serves(widget(), nil, 12))
    assert(not serves(widget(), {}, 12), "a cache with no items was accepted")
end)

t.done()
