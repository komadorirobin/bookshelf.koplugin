local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()
local Warm = dofile("lib/bookshelf_home_prewarm.lua")

t.test("prose is the default first profile", function()
    helpers.eq(Warm.profileOrder(nil), { "prose", "comics" })
end)

t.test("the last comics profile is prioritised", function()
    helpers.eq(Warm.profileOrder("comics"), { "comics", "prose" })
end)

t.test("unknown saved values fall back safely", function()
    helpers.eq(Warm.profileOrder("stale-profile"), { "prose", "comics" })
end)

t.test("cancelling a queued cover releases its raw buffer once", function()
    local freed = 0
    local job = {
        kind = "cover",
        cover_bb = { free = function() freed = freed + 1 end },
    }
    Warm.releaseJob(job)
    Warm.releaseJob(job)
    helpers.eq(freed, 1)
    helpers.eq(job.cover_bb, nil)
end)

t.done()
