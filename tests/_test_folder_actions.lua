package.path = "./?.lua;./?/init.lua;" .. package.path

local t = dofile("tests/_helpers.lua").runner()
local FolderActions = require("lib/bookshelf_folder_actions")

t.test("collect returns registered folder actions in stable order", function()
    package.loaded[FolderActions.REGISTRY_KEY] = {
        zeta = function(folder)
            return { text = "Z " .. folder.label, callback = function() end }
        end,
        alpha = function()
            return {
                { text = "A1", callback = function() end },
                { text = "A2", callback = function() end },
            }
        end,
    }
    local actions = FolderActions.collect({ label = "Manga" })
    assert(#actions == 3)
    assert(actions[1].text == "A1")
    assert(actions[2].text == "A2")
    assert(actions[3].text == "Z Manga")
end)

t.test("bad providers and malformed actions are ignored", function()
    package.loaded[FolderActions.REGISTRY_KEY] = {
        broken = function() error("provider failed") end,
        malformed = function() return { text = "No callback" } end,
        valid = function() return { text = "Works", callback = function() end } end,
    }
    local actions = FolderActions.collect({})
    assert(#actions == 1)
    assert(actions[1].text == "Works")
end)

package.loaded[FolderActions.REGISTRY_KEY] = nil
t.done()
