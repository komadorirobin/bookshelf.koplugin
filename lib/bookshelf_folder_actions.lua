-- Extension point for actions supplied by other plugins on folder cards.
-- Providers live in package.loaded so plugins can register before or after
-- Bookshelf itself is loaded without introducing a hard dependency.
local M = {}

M.REGISTRY_KEY = "bookshelf_folder_action_providers"

local function addAction(actions, value)
    if type(value) ~= "table" then return end
    if type(value.text) == "string" and type(value.callback) == "function" then
        actions[#actions + 1] = value
        return
    end
    for _i = 1, #value do addAction(actions, value[_i]) end
end

function M.collect(folder)
    local registry = package.loaded[M.REGISTRY_KEY]
    if type(registry) ~= "table" then return {} end

    local keys = {}
    for key, provider in pairs(registry) do
        if type(provider) == "function" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local actions = {}
    for _i = 1, #keys do
        local ok, provided = pcall(registry[keys[_i]], folder)
        if ok then addAction(actions, provided) end
    end
    return actions
end

return M
