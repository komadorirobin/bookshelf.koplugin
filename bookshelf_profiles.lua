-- bookshelf_profiles.lua
-- Fixed library profiles used by external launchers such as SimpleUI.

local Profiles = {}

local PROFILE_DEFS = {
    prose = {
        key = "prose",
        label = "Books",
        folder_sort = "author",
        roots = {
            "/storage/emulated/0/ePubs/Fiktion",
            "/storage/emulated/0/ePubs/Facklitteratur",
            "/storage/emulated/0/ePubs/Lyrik",
        },
        chips = {
            {
                key = "profile_fiction",
                label = "Fiktion",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Fiktion",
            },
            {
                key = "profile_nonfiction",
                label = "Facklitteratur",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Facklitteratur",
            },
            {
                key = "profile_poetry",
                label = "Lyrik",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Lyrik",
            },
            { key = "authors", label = "Authors", kind = "authors" },
            { key = "latest", label = "Latest", kind = "latest" },
        },
    },
    comics = {
        key = "comics",
        label = "Comics",
        folder_sort = "series",
        roots = {
            "/storage/emulated/0/ePubs/Manga",
            "/storage/emulated/0/ePubs/Serier",
        },
        chips = {
            {
                key = "profile_manga",
                label = "Manga",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Manga",
            },
            {
                key = "profile_comics",
                label = "Serier",
                kind = "folder",
                path = "/storage/emulated/0/ePubs/Serier",
            },
            { key = "next", label = "Next", kind = "next" },
            { key = "authors", label = "Authors", kind = "authors" },
            { key = "latest", label = "Latest", kind = "latest" },
        },
    },
}

function Profiles.get(key)
    return key and PROFILE_DEFS[key] or nil
end

function Profiles.defaultChip(profile)
    return profile and profile.chips and profile.chips[1] and profile.chips[1].key
end

function Profiles.chip(profile, key)
    if not (profile and profile.chips and key) then return nil end
    for _, chip in ipairs(profile.chips) do
        if chip.key == key then return chip end
    end
    return nil
end

function Profiles.scope(profile)
    if not (profile and profile.roots and #profile.roots > 0) then return nil end
    return { roots = profile.roots }
end

function Profiles.isFolderSortValid(sort_key)
    return sort_key == "author"
        or sort_key == "series"
        or sort_key == "title"
        or sort_key == "natural"
        or sort_key == "date_added"
        or sort_key == "last_read"
        or sort_key == "size"
        or sort_key == "format"
        or sort_key == "percent_unopened_first"
        or sort_key == "percent_unopened_last"
        or sort_key == "percent_natural"
end

function Profiles.folderSort(profile)
    if not profile then return nil end
    local default = profile.folder_sort
    local saved = G_reader_settings
        and type(G_reader_settings.readSetting) == "function"
        and profile.key
        and G_reader_settings:readSetting("bookshelf_profile_sort_" .. profile.key)
        or nil
    if Profiles.isFolderSortValid(saved) then return saved end
    return default
end

local function normalizePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
    return path
end

local function pathInRoot(filepath, root)
    local fp = normalizePath(filepath)
    root = normalizePath(root)
    if not fp or not root then return false end
    return fp == root or fp:sub(1, #root + 1) == (root .. "/")
end

function Profiles.matchFile(filepath)
    local best_key, best_len
    for key, profile in pairs(PROFILE_DEFS) do
        for _, root in ipairs(profile.roots or {}) do
            if pathInRoot(filepath, root) then
                local len = #normalizePath(root)
                if not best_len or len > best_len then
                    best_key = key
                    best_len = len
                end
            end
        end
    end
    return best_key and PROFILE_DEFS[best_key] and best_key or nil
end

return Profiles
