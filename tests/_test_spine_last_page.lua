-- tests/_test_spine_last_page.lua
-- Issue 463 (second half): in spine view the ">>" button stopped short of the
-- end on the first tap ("215-258 of 355"). It asked _spineTotalPages(), which
-- only READS the page map; before anything had built it, the tap fell back to
-- the view-size estimate and jumped there. A spine shelf's last page now comes
-- from the map, built on the tap: _spineCursorForPage builds it and clamps a
-- page past the end to the last one.
-- Run from the plugin root: lua tests/_test_spine_last_page.lua
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local src = io.open("lib/bookshelf_widget.lua"):read("*a")

t.test("the last-page button builds the spine page map on the tap", function()
    local cb = src:match('icon = "chevron.last".-callback%s*=%s*(.-)margin%s*=%s*bm%("last"%)')
    assert(cb, "the last-page button moved")
    assert(cb:find("_isSpineMode()", 1, true) and cb:find("math.huge", 1, true),
        "spine mode still jumps to the estimated last page")
end)

t.test("_spineCursorForPage builds the map and clamps past the end", function()
    local f = src:match("function BookshelfWidget:_spineCursorForPage%(p%).-\nend")
    assert(f and f:find("_spinePageFirsts(true)", 1, true) and f:find("if p > #firsts then p = #firsts end", 1, true))
end)

-- Execute the real jump helper and button callback together: source checks
-- alone missed an upstream callback calling go_page while the fork uses go.
local function lastPageCallback(bw, open_ended, total_pages)
    local footer = assert(src:match("function BookshelfWidget:_buildPaginationFooter%([^\n]+\n.-\nend\n"))
    local jump = assert(footer:match("    local function go%(p%)\n.-\n    end\n"))
    local callback = assert(footer:match('icon = "chevron.last".-callback%s*=%s*(.-)margin%s*=%s*bm%("last"%)'))
    callback = callback:gsub(",%s*$", "")
    local code = jump .. "\nreturn " .. callback
    local env = { bw = bw, open_ended = open_ended, total_pages = total_pages, math = math }
    if setfenv then
        local chunk = assert(loadstring(code, "last-page callback"))
        setfenv(chunk, env)
        return chunk()
    end
    return assert(load(code, "last-page callback", "t", env))()
end

local function shelf(spine)
    return {
        page = 1, _cursor = 1, _spine_hist = { 1 },
        _isSpineMode = function() return spine end,
        _spineTotalPages = function() return nil end,
        _markOpdsNav = function(self) self.marked = true end,
        _spineCursorForPage = function(self, p)
            self.requested_page = p
            return 301
        end,
        _viewSize = function() return 10 end,
        _clampCursor = function(self) self._cursor = math.min(self._cursor, 301) end,
        _syncPageFromCursor = function(self) self.synced = true end,
        _swapShelvesInPlace = function(self) self.swaps = (self.swaps or 0) + 1 end,
        _schedulePreload = function(self, dir) self.preload = dir end,
        _opdsWalkToEnd = function(self) self.walks = (self.walks or 0) + 1 end,
    }
end

t.test("the last-page callback uses the fork's jump helper in spine mode", function()
    local bw = shelf(true)
    lastPageCallback(bw, false, 4)()
    assert(bw.requested_page == math.huge, "the estimate must not limit the spine jump")
    assert(bw._cursor == 301 and #bw._spine_hist == 0)
    assert(bw.marked and bw.synced and bw.swaps == 1 and bw.preload == 1)
end)

t.test("the last-page callback still uses normal page counts outside spine mode", function()
    local bw = shelf(false)
    lastPageCallback(bw, false, 4)()
    assert(bw._cursor == 31 and bw.requested_page == nil)
    assert(bw.marked and bw.synced and bw.swaps == 1 and bw.preload == 1)
end)

t.test("the last-page callback walks an open-ended OPDS feed instead of jumping", function()
    local bw = shelf(true)
    lastPageCallback(bw, true, 4)()
    assert(bw.walks == 1 and bw._cursor == 1)
    assert(bw.requested_page == nil and bw.swaps == nil and bw.marked == nil)
end)

t.done()
