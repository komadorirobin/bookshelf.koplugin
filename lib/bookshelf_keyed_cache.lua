-- Disposable, independently versioned disk entries. The full key is checked
-- on read, so a filename-hash collision is a cache miss, never wrong data.
local M = {}

local function filename(key)
    local a, b = 5381, 52711
    for i = 1, #key do
        a = (a * 33 + key:byte(i)) % 4294967296
        b = (b * 65599 + key:byte(i)) % 4294967296
    end
    return string.format("%08x%08x", a, b)
end

function M.new(namespace, version)
    assert(namespace:match("^[%w_]+$"))
    local known, cached_dir = {}, nil
    local function directory()
        if cached_dir then return cached_dir end
        local ok, path = pcall(function()
            local root = require("datastorage"):getDataDir() .. "/cache/bookshelf/"
            local lfs = require("libs/libkoreader-lfs")
            pcall(lfs.mkdir, root)
            local dir = root .. namespace .. "/"
            local made, result = pcall(lfs.mkdir, dir)
            if (made and result) or (lfs.attributes and lfs.attributes(dir, "mode") == "directory") then
                cached_dir = dir
            end
            return dir
        end)
        return ok and path or nil
    end
    local function persist(name)
        local dir = directory()
        if not dir then return nil end
        local ok, p = pcall(function()
            return require("persist"):new{ path = dir .. name, codec = "zstd" }
        end)
        if ok then known[name] = true; return p end
    end
    local store = {}
    function store.read(key)
        local p = persist(filename(key))
        if not p then return nil end
        local ok, entry = pcall(p.load, p)
        if ok and type(entry) == "table" and entry.version == version
                and entry.key == key and type(entry.value) == "table" then
            return entry.value
        end
    end
    function store.write(key, value)
        local p = persist(filename(key))
        if p then return pcall(p.save, p, { version = version, key = key, value = value }) end
        return false
    end
    function store.remove(key)
        local p = persist(filename(key))
        if p then pcall(p.delete, p) end
    end
    function store.clear()
        local dir = directory()
        if dir then
            pcall(function()
                for name in require("libs/libkoreader-lfs").dir(dir) do
                    if #name == 16 and name:match("^%x+$") then known[name] = true end
                end
            end)
        end
        for name in pairs(known) do
            local p = persist(name)
            if p then pcall(p.delete, p) end
        end
        known = {}
    end
    return store
end

return M
