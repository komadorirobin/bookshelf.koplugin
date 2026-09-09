-- tests/_test_spine_page_number.lua
-- Spine pages hold a variable number of books, so page NUMBERS must come
-- from the page map, not ceil(total / view-size). The bug this pins: a
-- 121-book spine chip whose capacity estimate exceeded 121 reported one
-- page, so the footer's "last" (go_page(total_pages)) and skip-10 targeted
-- the page already showing and did nothing, while "next" kept working.
--
-- Run from the plugin root: lua tests/_test_spine_page_number.lua

package.path = "./?.lua;./?/init.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

local function bodyOf(signature, name)
    local body = src:match("\nfunction BookshelfWidget:" .. signature .. "\n(.-)\nend\n")
    assert(body, "could not find BookshelfWidget:" .. name)
    return body
end
local function compile(code, env)
    if _G.setfenv then local f = assert(_G.loadstring(code)); _G.setfenv(f, env); return f end
    return assert(load(code, "body", "t", env))
end
local env = { math = math, pcall = pcall, ipairs = ipairs, tostring = tostring }
local total_pages_body = bodyOf("_spineTotalPages%(%)", "_spineTotalPages")
local page_index_body  = bodyOf("_spinePageIndexForCursor%(cur%)", "_spinePageIndexForCursor")
local sync_body        = bodyOf("_syncPageFromCursor%(%)", "_syncPageFromCursor")

local function shelf(o)
    local self_tbl = {
        _isSpineMode = function() return o.spine end,
        _spinePageFirsts = function() return o.firsts end,
        _spineCursorForPage = function(_s, p)
            if not o.firsts then return nil end
            return o.firsts[math.min(p, #o.firsts)], #o.firsts
        end,
        _viewSize = function() return o.view end,
        _total_items = o.total, _total_pages = o.total_pages, _cursor = o.cursor,
    }
    self_tbl._spineTotalPages = function(s) return compile("local self = ...; " .. total_pages_body, env)(s) end
    self_tbl._spinePageIndexForCursor = function(s, cur) return compile("local self, cur = ...; " .. page_index_body, env)(s, cur) end
    self_tbl._syncPageFromCursor = function(s) return compile("local self = ...; " .. sync_body, env)(s) end
    return self_tbl
end

t.test("total pages come from the page map in spine mode", function()
    local s = shelf{ spine = true, firsts = { 1, 40, 80, 117 } }
    assert(s:_spineTotalPages() == 4, "four real pages")
    s = shelf{ spine = false, firsts = { 1, 40 } }
    assert(s:_spineTotalPages() == nil, "not spine: nil, the estimate stands")
    s = shelf{ spine = true, firsts = nil }
    assert(s:_spineTotalPages() == nil, "no map yet: nil")
end)

t.test("the cursor's page is looked up in the map", function()
    local s = shelf{ spine = true, firsts = { 1, 40, 80, 117 } }
    assert(s:_spinePageIndexForCursor(1) == 1)
    assert(s:_spinePageIndexForCursor(39) == 1)
    assert(s:_spinePageIndexForCursor(40) == 2)
    assert(s:_spinePageIndexForCursor(117) == 4)
    assert(s:_spinePageIndexForCursor(121) == 4, "past the last first: still the last page")
end)

t.test("the reported bug: last page is page 4 of 4, not 1 of 1", function()
    -- 121 books, capacity estimate 200 (> total): the old arithmetic said
    -- page 1 of 1 whatever the cursor.
    local s = shelf{ spine = true, firsts = { 1, 40, 80, 117 }, view = 200,
                     total = 121, total_pages = 4, cursor = 117 }
    s:_syncPageFromCursor()
    assert(s.page == 4, "cursor 117 is on page 4, got " .. tostring(s.page))
    s._cursor = 1; s:_syncPageFromCursor()
    assert(s.page == 1)
end)

t.test("cover/list page arithmetic is untouched", function()
    local s = shelf{ spine = false, view = 12, total = 30, total_pages = 3, cursor = 13 }
    s:_syncPageFromCursor()
    assert(s.page == 2, "cursor 13 of view 12 is page 2, got " .. tostring(s.page))
end)

t.done()
