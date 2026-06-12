--[[
Finds launchable plugin modules on the live FileManager instance, so start
menu items can launch them directly (games etc.) without the user wading
through the full Dispatcher action list.

FileManager registers its modules twice: as array entries (fm[i], tables
with a .name string) and as named fields (fm[key] = same table). scan()
walks the array, resolves each module's field key via a reverse map, and
keeps the ones that look like menu-visible plugins with a callable entry
point. Launch method resolution order:
  1. a conventional method: onShow / show / open / launch / onOpen;
  2. the camel-cased event handler "on<Key>";
  3. probe addToMainMenu and use the menu entry's callback - recorded as
     the sentinel "__menu_callback" because closures don't survive a
     restart; resolve() re-probes at launch time.
resolve() is the live half: given a stored {key, method} it returns a
callable launcher bound to the CURRENT fm instance, or nil when the
plugin is gone (uninstalled/disabled) - callers grey the entry out.
]]
local M = {}

M.SENTINEL = "__menu_callback"

-- KOReader-native FM modules that also live in the fm array; they are not
-- "plugins" in the user's sense and most have first-class dispatcher
-- actions already.
local NATIVE = {
    screenshot = true, menu = true, history = true, bookinfo = true,
    collections = true, filesearcher = true, folder_shortcuts = true,
    languagesupport = true, dictionary = true, wikipedia = true,
    devicestatus = true, devicelistener = true, networklistener = true,
    bookshelf = true, -- ourselves
}

local LAUNCH_METHODS = { "onShow", "show", "open", "launch", "onOpen" }

local function liveFM()
    local fm_mod = package.loaded["apps/filemanager/filemanager"]
    return fm_mod and fm_mod.instance or nil
end

-- Probe the module's addToMainMenu for its own menu entry. Returns the
-- entry table (probe[key], falling back to probe[mod.name]) or nil.
local function probeMenuEntry(mod, key)
    if type(mod.addToMainMenu) ~= "function" then return nil end
    local probe = {}
    local ok = pcall(mod.addToMainMenu, mod, probe)
    if not ok then return nil end
    local entry = probe[key]
    if entry == nil and type(mod.name) == "string" then
        entry = probe[mod.name]
    end
    return type(entry) == "table" and entry or nil
end

local function findMethod(mod, key)
    for _i, m in ipairs(LAUNCH_METHODS) do
        if type(mod[m]) == "function" then return m end
    end
    local camel = "on" .. key:sub(1, 1):upper() .. key:sub(2)
    if type(mod[camel]) == "function" then return camel end
    local entry = probeMenuEntry(mod, key)
    if entry and type(entry.callback) == "function" then
        return M.SENTINEL
    end
    return nil
end

-- -> { { key = <fm field name>, method = <method name>, title = <display> }, ... }
-- sorted by title; {} when nothing is launchable (or no live FM).
function M.scan()
    local ok, results = pcall(function()
        local fm = liveFM()
        if not fm then return {} end
        -- Reverse map: module table -> its fm field key.
        local key_of = {}
        for k, v in pairs(fm) do
            if type(k) == "string" and type(v) == "table" then
                key_of[v] = k
            end
        end
        local out, seen = {}, {}
        for _i, mod in ipairs(fm) do
            local key = type(mod) == "table" and type(mod.name) == "string"
                and key_of[mod] or nil
            if key and not NATIVE[key] and not seen[key]
                    and type(mod.addToMainMenu) == "function" then
                seen[key] = true
                local method = findMethod(mod, key)
                if method then
                    local entry = probeMenuEntry(mod, key)
                    local title = entry and type(entry.text) == "string"
                        and entry.text
                        or (key:sub(1, 1):upper() .. key:sub(2))
                    out[#out + 1] = { key = key, method = method, title = title }
                end
            end
        end
        table.sort(out, function(a, b) return a.title < b.title end)
        return out
    end)
    if not ok then return {} end
    return results
end

-- Cheap existence check for greying: NEVER calls third-party code (the
-- sentinel case only verifies the module + addToMainMenu are present),
-- so it is safe to run on every menu rebuild.
function M.exists(key, method)
    if type(key) ~= "string" or type(method) ~= "string" then return false end
    local fm = liveFM()
    local mod = fm and fm[key]
    if type(mod) ~= "table" then return false end
    if method == M.SENTINEL then
        return type(mod.addToMainMenu) == "function"
    end
    return type(mod[method]) == "function"
end

-- TouchMenu normally passes itself to menu callbacks ("so it can call our
-- closemenu() or updateItems()"); launching outside the menu we hand a
-- no-op stand-in so such callbacks don't index nil.
local TOUCHMENU_STUB = {
    closeMenu   = function() end,
    updateItems = function() end,
}

-- -> zero-arg launcher bound to the live module, or nil when unresolvable.
function M.resolve(key, method)
    if type(key) ~= "string" or type(method) ~= "string" then return nil end
    local fm = liveFM()
    local mod = fm and fm[key]
    if type(mod) ~= "table" then return nil end
    if method == M.SENTINEL then
        -- The menu callback is a closure that doesn't survive restarts;
        -- re-probe the module's addToMainMenu for a fresh one.
        local entry = probeMenuEntry(mod, key)
        local cb = entry and entry.callback
        if type(cb) ~= "function" then return nil end
        return function() return cb(TOUCHMENU_STUB) end
    end
    if type(mod[method]) ~= "function" then return nil end
    return function() return mod[method](mod) end
end

return M
