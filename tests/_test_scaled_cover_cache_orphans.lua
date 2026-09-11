-- tests/_test_scaled_cover_cache_orphans.lua
-- The cover cache never frees a bb it lets go of (live widgets may still hold
-- it), so those bbs are C heap the GC can't see until a FULL collect. The
-- cache now ACCOUNTS for them, and the widget forces a collect once the
-- orphaned bytes pass a threshold. This pins the accounting: every path that
-- drops a reference adds its bytes; reset zeroes them.
--
-- Run from the plugin root: lua tests/_test_scaled_cover_cache_orphans.lua

package.path = "./?.lua;" .. package.path
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
-- No disk backing: keep the test about memory accounting.
package.loaded["lib/bookshelf_cover_disk_cache"] = {
    store = function() return true end, load = function() return nil end,
    drop = function() end, clear = function() end,
}

local Cache = require("lib/bookshelf_scaled_cover_cache")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function bb(w, h)
    return { stride = w, getWidth = function() return w end, getHeight = function() return h end }
end

local function reset()
    Cache:clear()
    Cache:resetOrphanBytes()
    Cache:setByteBudget(1024 * 1024 * 1024)
end

t.test("a fresh cache reports no orphans", function()
    reset()
    eq(Cache:orphanBytes(), 0)
end)

t.test("a prefer-larger replacement orphans the old entry's bytes", function()
    reset()
    Cache:put("/b/a", bb(100, 100))          -- 10,000 bytes resident
    Cache:put("/b/a", bb(200, 200))          -- larger: replaces
    eq(Cache:orphanBytes(), 10000, "old entry's bytes must be counted")
    eq(Cache._bytes, 40000, "resident bytes track the new entry only")
end)

t.test("a rejected smaller put orphans nothing", function()
    reset()
    Cache:put("/b/a", bb(200, 200))
    Cache:put("/b/a", bb(100, 100))          -- kept existing
    eq(Cache:orphanBytes(), 0)
end)

t.test("eviction orphans the evicted bytes", function()
    reset()
    Cache:setByteBudget(25000)               -- room for two 100x100, not three
    Cache:put("/b/1", bb(100, 100))
    Cache:put("/b/2", bb(100, 100))
    Cache:put("/b/3", bb(100, 100))
    eq(Cache:orphanBytes(), 10000, "one eviction, one entry's bytes")
end)

t.test("drop orphans that book's bytes", function()
    reset()
    Cache:put("/b/a", bb(100, 100))
    Cache:drop("/b/a")
    eq(Cache:orphanBytes(), 10000)
    Cache:drop("/b/a")                       -- not resident: nothing more
    eq(Cache:orphanBytes(), 10000)
end)

t.test("clear orphans everything resident", function()
    reset()
    Cache:put("/b/1", bb(100, 100))
    Cache:put("/b/2", bb(100, 100))
    Cache:clear()
    eq(Cache:orphanBytes(), 20000)
end)

t.test("reset zeroes the count", function()
    reset()
    Cache:put("/b/a", bb(100, 100))
    Cache:drop("/b/a")
    Cache:resetOrphanBytes()
    eq(Cache:orphanBytes(), 0)
end)

t.done()
