-- bookshelf_hardcover.lua
-- Optional integration with hardcoverapp.koplugin.
--
-- Hardcover's KOReader plugin stores the local-file -> Hardcover book link in
-- <settings>/hardcoversync_settings.lua, but it does not persist Hardcover's
-- public book rating there. Bookshelf therefore keeps its own small rating
-- cache, refreshed on demand from Hardcover's API module, and only reads that
-- cache during normal shelf rendering.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local Hardcover = {}

local HC_SETTINGS_FILE = "hardcoversync_settings.lua"
local CACHE_KEY        = "hardcover_ratings"
local CACHE_TIME_KEY   = "hardcover_ratings_fetched_at"

local _hc_settings
local _hc_books
local _ratings_cache

local function _settingsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/" .. HC_SETTINGS_FILE
end

local function _openHardcoverSettings()
    if _hc_settings then return _hc_settings end
    local LuaSettings = require("luasettings")
    _hc_settings = LuaSettings:open(_settingsPath())
    return _hc_settings
end

local function _readHardcoverBooks(force)
    if _hc_books and not force then return _hc_books end
    if force then _hc_settings = nil end
    local ok, settings = pcall(_openHardcoverSettings)
    if not ok or not settings then
        _hc_books = {}
        return _hc_books
    end
    local ok_books, books = pcall(settings.readSetting, settings, "books")
    _hc_books = (ok_books and type(books) == "table") and books or {}
    return _hc_books
end

local function _readRatingsCache()
    if _ratings_cache then return _ratings_cache end
    local raw = BookshelfSettings.read(CACHE_KEY, {})
    _ratings_cache = type(raw) == "table" and raw or {}
    return _ratings_cache
end

local function _saveRatingsCache(cache)
    _ratings_cache = cache or {}
    BookshelfSettings.save(CACHE_KEY, _ratings_cache)
    BookshelfSettings.save(CACHE_TIME_KEY, os.time())
end

local function _ratingFromCacheEntry(entry)
    if type(entry) ~= "table" then return nil end
    local rating = entry.rating
    if rating == false then return nil end
    return tonumber(rating)
end

function Hardcover.invalidate()
    _hc_books = nil
    _ratings_cache = nil
end

function Hardcover.getCachedAt()
    return tonumber(BookshelfSettings.read(CACHE_TIME_KEY))
end

function Hardcover.getCacheStats()
    local cache = _readRatingsCache()
    local linked, rated = 0, 0
    local books = _readHardcoverBooks(false)
    local seen = {}
    for _filepath, cfg in pairs(books) do
        if type(cfg) == "table" and cfg.book_id then
            local key = tostring(cfg.book_id)
            if not seen[key] then
                seen[key] = true
                linked = linked + 1
                if _ratingFromCacheEntry(cache[key]) then
                    rated = rated + 1
                end
            end
        end
    end
    return {
        linked = linked,
        rated = rated,
        fetched_at = Hardcover.getCachedAt(),
    }
end

function Hardcover.getLink(filepath)
    if not filepath then return nil end
    local books = _readHardcoverBooks(false)
    local link = books[filepath]
    return type(link) == "table" and link or nil
end

function Hardcover.getCachedRating(book_id)
    if not book_id then return nil end
    return _ratingFromCacheEntry(_readRatingsCache()[tostring(book_id)])
end

function Hardcover.enrichBook(book)
    if not book or not book.filepath then return book end
    local link = Hardcover.getLink(book.filepath)
    if not link then return book end

    book.hardcover_book_id = tonumber(link.book_id) or link.book_id
    book.hardcover_edition_id = tonumber(link.edition_id) or link.edition_id
    book.hardcover_title = link.title
    book.hardcover_rating = Hardcover.getCachedRating(link.book_id)
    return book
end

local function _collectLinkedBookIds()
    local ids, seen = {}, {}
    for _filepath, cfg in pairs(_readHardcoverBooks(true)) do
        if type(cfg) == "table" and cfg.book_id then
            local id = tonumber(cfg.book_id)
            if id and not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return ids
end

local function _loadApi()
    local ok, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok or not Api or type(Api.query) ~= "function" then
        return nil, "Hardcover plugin/API module could not be loaded"
    end
    return Api
end

local function _getUserId(Api, settings)
    local user_id = settings:readSetting("user_id")
    if user_id then return tonumber(user_id) or user_id end
    if not Api.me then return nil, "Hardcover user id is missing" end
    local me = Api:me()
    user_id = me and me.id
    if not user_id then return nil, "Could not fetch Hardcover user id" end
    settings:saveSetting("user_id", user_id)
    settings:flush()
    return tonumber(user_id) or user_id
end

function Hardcover.refreshRatings()
    local Api, api_err = _loadApi()
    if not Api then return false, api_err end

    local ok_settings, settings = pcall(_openHardcoverSettings)
    if not ok_settings or not settings then
        return false, "Could not open Hardcover settings"
    end

    local ids = _collectLinkedBookIds()
    if #ids == 0 then
        _saveRatingsCache({})
        return true, {
            linked = 0,
            rated = 0,
            updated = 0,
        }
    end

    local user_id, user_err = _getUserId(Api, settings)
    if not user_id then return false, user_err end

    local query = [[
        query ($ids: [Int!], $userId: Int!) {
          books(where: { id: { _in: $ids }}) {
            id
            rating
            ratings_count
            user_books(where: { user_id: { _eq: $userId }}) {
              id
              rating
            }
          }
        }
    ]]

    local data, err = Api:query(query, { ids = ids, userId = user_id })
    if not data or type(data.books) ~= "table" then
        return false, err and "Hardcover rating refresh failed" or "No response from Hardcover"
    end

    local now = os.time()
    local cache = {}
    for _, id in ipairs(ids) do
        cache[tostring(id)] = { rating = false, fetched_at = now }
    end

    local rated = 0
    for _, row in ipairs(data.books) do
        if type(row) == "table" and row.id then
            local rating = tonumber(row.rating)
            local user_book = type(row.user_books) == "table" and row.user_books[1] or nil
            local user_rating = user_book and tonumber(user_book.rating) or nil
            if rating then rated = rated + 1 end
            cache[tostring(row.id)] = {
                rating = rating or false,
                ratings_count = tonumber(row.ratings_count) or 0,
                user_book_id = user_book and user_book.id or nil,
                user_rating = user_rating or false,
                fetched_at = now,
            }
        end
    end

    _saveRatingsCache(cache)
    return true, {
        linked = #ids,
        rated = rated,
        updated = #data.books,
    }
end

return Hardcover
