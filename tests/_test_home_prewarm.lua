-- Pure-Lua tests for SimpleUI Home cache prewarming in main.lua.

package.path = "./?.lua;./?/init.lua;" .. package.path
local runner = dofile("tests/_helpers.lua").runner()

local WC = {}
WC.__index = WC
function WC:extend(t)
    t = t or {}
    setmetatable(t, { __index = self })
    t.extend, t.new = self.extend, self.new
    return t
end
function WC:new(t) t = t or {}; setmetatable(t, { __index = self }); return t end

package.loaded["ui/widget/container/widgetcontainer"] = WC
package.loaded["lib/bookshelf_settings_store"] = {
    read = function() end,
    save = function() end,
    flush = function() end,
    delete = function() end,
}
package.loaded["ui/uimanager"] = {
    show = function() end,
    close = function() end,
    setDirty = function() end,
    nextTick = function() end,
    scheduleIn = function() end,
}
package.loaded["logger"] = setmetatable({}, {
    __index = function() return function() end end,
})
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["ffi/util"] = { template = function(s) return s end }

local scopes = {
    prose = { roots = { "/books/prose" } },
    comics = { roots = { "/books/comics" } },
}
package.loaded["lib/bookshelf_profiles"] = {
    get = function(key) return { key = key, roots = scopes[key].roots } end,
    scope = function(profile) return scopes[profile.key] end,
}

local warmed = {}
package.loaded["lib/bookshelf_book_repository"] = {
    getAllFilepaths = function(scope)
        warmed[#warmed + 1] = scope
        return {}
    end,
}

local Bookshelf = assert(dofile("main.lua"), "main.lua did not return plugin")

runner.test("Home prewarm warms both profile scopes", function()
    warmed = {}
    local active = true
    local accepted = Bookshelf:onPrepareBookshelfHome{
        is_alive = function() return true end,
        is_active = function() return active end,
    }
    assert(accepted == true)
    assert(#warmed == 2)
    assert(warmed[1] == scopes.prose)
    assert(warmed[2] == scopes.comics)
end)

runner.test("Home prewarm rejects an inactive Home screen", function()
    warmed = {}
    local accepted = Bookshelf:onPrepareBookshelfHome{
        is_alive = function() return true end,
        is_active = function() return false end,
    }
    assert(accepted == false)
    assert(#warmed == 0)
end)

runner.done()

