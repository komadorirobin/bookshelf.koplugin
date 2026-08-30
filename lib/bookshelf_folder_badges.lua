-- Extension point for a compact metadata badge on folder cards.
-- Providers are kept in package.loaded so optional plugins can register
-- without either plugin depending on the other's load order.
local M = {}

M.REGISTRY_KEY = "bookshelf_folder_badge_providers"

function M.resolve(folder)
    local registry = package.loaded[M.REGISTRY_KEY]
    if type(registry) ~= "table" then return nil end

    local keys = {}
    for key, provider in pairs(registry) do
        if type(provider) == "function" then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    for _i = 1, #keys do
        local ok, value = pcall(registry[keys[_i]], folder)
        if ok then
            if type(value) == "string" and value ~= "" then
                return { text = value }
            end
            if type(value) == "table" and type(value.text) == "string"
                    and value.text ~= "" then
                return value
            end
        end
    end
    return nil
end

return M
