-- tests/_test_cursor_follows_book.lua
-- Paging the shelf to keep a chosen book on screen across a view-size change
-- (BookshelfWidget:_setCursorToShow) -- issue #369.
--
-- Usage (from plugin root): lua tests/_test_cursor_follows_book.lua
--
-- THE BUG. This runs immediately after a collapse or expand -- that is what it
-- is for, and its own comment says to call it after toggling. But it clamped
-- with _clampCursor() and no total, which makes _maxCursor fall back to
-- self._total_pages: the page count for the view size we just LEFT.
--
-- Collapsing shrinks the view, so the real page count GROWS while the stale
-- one stays small, and the clamp drags the cursor backwards. The worst case is
-- a folder whose books all fit on ONE expanded page: _total_pages is 1, max
-- cursor comes out as 1, and tapping a book on the second collapsed page sent
-- the shelf to page 1 -- which is exactly what the reporter described, right
-- down to "a book that would be on page 2, or any page higher, in hero view".
--
-- bookshelf_widget.lua is 19k lines and needs the whole KOReader stack, so the
-- method is extracted by name and run against a plain table carrying only the
-- fields it touches. _maxCursor and _clampCursor are extracted with it, so the
-- interaction between the three is what is under test rather than a stub of it.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local Shelf = {}
do
    local src = io.open("lib/bookshelf_widget.lua"):read("a")
    for _i, name in ipairs({ "_setCursorToShow", "_maxCursor", "_clampCursor",
                             "_syncPageFromCursor" }) do
        local body = src:match("\nfunction BookshelfWidget:" .. name
                               .. "%((.-)%)\n(.-)\nend\n")
        local args, code = src:match("\nfunction BookshelfWidget:" .. name
                                     .. "%((.-)%)\n(.-)\nend\n")
        assert(code, "BookshelfWidget:" .. name .. " is gone or was renamed")
        Shelf[name] = assert(load("return function(self" ..
            (args ~= "" and ", " .. args or "") .. ")\n" .. code .. "\nend"))()
    end
end

-- A shelf mid-collapse: the view size is already the NEW one, _total_pages is
-- still the old view's, which is the whole trap.
local function shelf(view, total_items, stale_total_pages)
    local s = {
        _cursor = 1,
        _total_items = total_items,
        _total_pages = stale_total_pages,
        _viewSize = function() return view end,
        -- The cursor stack asks the mode before doing view-size arithmetic
        -- (spine pages hold a variable count); these tests pin the fixed-view
        -- behaviour, so the stub answers covers.
        _isSpineMode = function() return false end,
    }
    for k, fn in pairs(Shelf) do s[k] = fn end
    return s
end

t.test("a book on the second collapsed page is followed, not abandoned", function()
    -- The reporter's case. 18 books: one expanded page of 20, two collapsed
    -- pages of 12. Tapping book 15 must land on the page holding it.
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(15)
    eq(s._cursor, 13, "the shelf went back to page 1 instead of following")
    -- Only the CURSOR is asserted here. _syncPageFromCursor clamps its label
    -- against the same stale _total_pages, so page reads 1 at this instant --
    -- harmless, because the _rebuild that always follows recomputes both from
    -- the new view size. The cursor is what that rebuild slices with, so it is
    -- the output that has to be right.
end)

t.test("a stale page count cannot drag the cursor backwards", function()
    -- Same shape, further out: 30 books, expanded page count of 2, collapsed
    -- view of 12 means three real pages.
    local s = shelf(12, 30, 2)
    s:_setCursorToShow(25)
    eq(s._cursor, 25, "clamped against the page count of the view we left")
end)

t.test("a book on the first page still lands on the first page", function()
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(3)
    eq(s._cursor, 1)
end)

t.test("the cursor is page-ALIGNED, not set to the book", function()
    -- The shelf pages in whole views; landing mid-page would leave the row
    -- boundaries out of step with the chevrons.
    local s = shelf(12, 100, 9)
    s:_setCursorToShow(14)
    eq(s._cursor, 13)
end)

t.test("a genuinely out-of-range index is still clamped", function()
    -- The clamp still has to do its job -- this is not about removing it.
    local s = shelf(12, 18, 1)
    s:_setCursorToShow(999)
    assert(s._cursor <= 13, "cursor ran past the end: " .. s._cursor)
end)

t.test("no total yet falls back to the old behaviour rather than erroring", function()
    -- Before the first fetch there is nothing to clamp against; _maxCursor's
    -- page-count path is the only answer available.
    local s = shelf(12, nil, 3)
    s:_setCursorToShow(14)
    assert(type(s._cursor) == "number" and s._cursor >= 1)
end)

t.test("a nil index is a no-op", function()
    -- _globalIndexOfFilepath answers nil when the book is not on the page.
    local s = shelf(12, 18, 1)
    s._cursor = 7
    s:_setCursorToShow(nil)
    eq(s._cursor, 7, "a book we could not locate moved the shelf anyway")
end)

t.done()
