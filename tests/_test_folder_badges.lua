package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()
local FolderBadges = require("lib/bookshelf_folder_badges")

t.test("resolve returns the first valid badge in stable provider order", function()
    package.loaded[FolderBadges.REGISTRY_KEY] = {
        zeta = function() return "Z 9.1" end,
        alpha = function(folder) return { text = "A " .. folder.label } end,
    }
    local badge = FolderBadges.resolve({ label = "Manga" })
    assert(badge.text == "A Manga")
end)

t.test("broken and malformed providers are ignored", function()
    package.loaded[FolderBadges.REGISTRY_KEY] = {
        broken = function() error("provider failed") end,
        empty = function() return { text = "" } end,
        valid = function() return "MAL 8.72" end,
    }
    local badge = FolderBadges.resolve({})
    assert(badge.text == "MAL 8.72")
end)

package.loaded[FolderBadges.REGISTRY_KEY] = nil
t.done()
