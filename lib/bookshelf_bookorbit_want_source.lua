-- Read SimpleUI's cached BookOrbit "Want to Read" file list without making
-- Bookshelf depend on the BookOrbit network client. The live SimpleUI modules
-- are preferred; the persisted settings file is a restart-safe fallback.

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

local CACHE_KEY = "simpleui_bookorbit_want_files"
local _disk_stamp
local _disk_files = {}

local function _cleanPaths(raw)
    local files, seen = {}, {}
    if type(raw) ~= "table" then return files end
    for _, path in ipairs(raw) do
        if type(path) == "string" and path ~= "" and not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    return files
end

local function _copy(files)
    local out = {}
    for i, path in ipairs(files or {}) do out[i] = path end
    return out
end

local function _liveFiles()
    local integration = package.loaded["integrations/sui_bookorbit_want"]
    if integration and type(integration.getCachedFiles) == "function" then
        local ok, files = pcall(integration.getCachedFiles)
        if ok and type(files) == "table" then return _cleanPaths(files) end
    end

    local store = package.loaded["sui_store"]
    if store and type(store.readSetting) == "function" then
        local ok, files = pcall(store.readSetting, store, CACHE_KEY)
        if ok and type(files) == "table" then return _cleanPaths(files) end
    end
    return nil
end

local function _settingsPath()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage and type(DataStorage.getSettingsDir) == "function") then
        return nil
    end
    return DataStorage:getSettingsDir() .. "/simpleui/sui_settings.lua"
end

local function _persistedFiles()
    local path = _settingsPath()
    if not path then return {} end
    local attr = lfs.attributes(path)
    if type(attr) ~= "table" or attr.mode ~= "file" then return {} end
    local stamp = tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
    if stamp == _disk_stamp then return _copy(_disk_files) end

    local ok_ls, LuaSettings = pcall(require, "luasettings")
    if not (ok_ls and LuaSettings and type(LuaSettings.open) == "function") then
        return {}
    end
    local ok_open, store = pcall(LuaSettings.open, LuaSettings, path)
    if not (ok_open and store and type(store.readSetting) == "function") then
        logger.warn("[bookshelf] could not read SimpleUI BookOrbit cache")
        return {}
    end
    local ok_read, raw = pcall(store.readSetting, store, CACHE_KEY)
    if not ok_read then return {} end
    _disk_stamp = stamp
    _disk_files = _cleanPaths(raw)
    return _copy(_disk_files)
end

local function _signature(files)
    -- A compact deterministic revision keeps Bookshelf's source cache valid
    -- until the Want-to-Read membership actually changes.
    local hash = 5381
    for _, path in ipairs(files or {}) do
        for i = 1, #path do
            hash = (hash * 33 + path:byte(i)) % 4294967296
        end
        hash = (hash * 33) % 4294967296
    end
    return string.format("%d:%08x", #(files or {}), hash)
end

function M.snapshot()
    local files = _liveFiles() or _persistedFiles()
    return files, _signature(files)
end

return M
