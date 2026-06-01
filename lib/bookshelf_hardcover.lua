-- bookshelf_hardcover.lua
-- Optional Hardcover enrichment for Bookshelf.
--
-- Normal shelf rendering never talks to the network. This module only reads
-- Bookshelf's local link/enrichment caches there. Network calls happen from
-- explicit user actions: link a book, refresh one book, or refresh all linked
-- books.

local BookshelfSettings = require("lib/bookshelf_settings_store")

local Hardcover = {}

local HC_SETTINGS_FILE = "hardcoversync_settings.lua"
local LINKS_KEY        = "hardcover_links"
local CACHE_KEY        = "hardcover_enrichment"

local _links
local _external_links
local _enrichment_cache
local _hc_settings
local _hc_settings_object

local function _settingsPath()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/" .. HC_SETTINGS_FILE
end

local function _cacheDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/bookshelf_hardcover"
end

local function _ensureDir(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or type(lfs.attributes) ~= "function" then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end
    if type(lfs.mkdir) == "function" then
        local ok = pcall(lfs.mkdir, path)
        return ok and lfs.attributes(path, "mode") == "directory"
    end
    return false
end

local function _openExternalSettings()
    if _hc_settings then return _hc_settings end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes
            and lfs.attributes(_settingsPath(), "mode") ~= "file" then
        return nil
    end
    local LuaSettings = require("luasettings")
    _hc_settings = LuaSettings:open(_settingsPath())
    return _hc_settings
end

local function _readLinks()
    if _links then return _links end
    local raw = BookshelfSettings.read(LINKS_KEY, {})
    _links = type(raw) == "table" and raw or {}
    return _links
end

local function _saveLinks(links)
    _links = links or {}
    BookshelfSettings.save(LINKS_KEY, _links)
end

local function _readExternalLinks(force)
    if _external_links and not force then return _external_links end
    if force then _hc_settings = nil end
    local ok, settings = pcall(_openExternalSettings)
    if not ok or not settings then
        _external_links = {}
        return _external_links
    end
    local ok_books, books = pcall(settings.readSetting, settings, "books")
    _external_links = (ok_books and type(books) == "table") and books or {}
    return _external_links
end

local function _readEnrichmentCache()
    if _enrichment_cache then return _enrichment_cache end
    local raw = BookshelfSettings.read(CACHE_KEY, {})
    _enrichment_cache = type(raw) == "table" and raw or {}
    return _enrichment_cache
end

local function _saveEnrichmentCache(cache)
    _enrichment_cache = cache or {}
    BookshelfSettings.save(CACHE_KEY, _enrichment_cache)
end

local function _cacheKey(book_id, edition_id)
    if not book_id then return nil end
    if edition_id then
        return tostring(book_id) .. ":" .. tostring(edition_id)
    end
    return tostring(book_id)
end

local function _shallowCopy(t)
    local out = {}
    if type(t) == "table" then
        for k, v in pairs(t) do out[k] = v end
    end
    return out
end

local function _authorString(book)
    if not book then return nil end
    if type(book.authors) == "table" and #book.authors > 0 then
        return table.concat(book.authors, ", ")
    end
    return book.author
end

local function _filenameTitle(filepath)
    local name = tostring(filepath or ""):match("([^/]+)$") or ""
    name = name:gsub("%.[^%.]+$", ""):gsub("_", " ")
    return name ~= "" and name or nil
end

local function _shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function _xmlDecode(s)
    if not s then return "" end
    return (s:gsub("&lt;", "<")
             :gsub("&gt;", ">")
             :gsub("&quot;", "\"")
             :gsub("&apos;", "'")
             :gsub("&amp;", "&")
             :gsub("^%s+", "")
             :gsub("%s+$", ""))
end

local function _attr(attrs, name)
    if type(attrs) ~= "string" then return nil end
    local pattern_dq = name .. '%s*=%s*"([^"]+)"'
    local pattern_sq = name .. "%s*=%s*'([^']+)'"
    return attrs:match(pattern_dq) or attrs:match(pattern_sq)
end

local function _normaliseIdentifierToken(attrs, value)
    value = _xmlDecode(value)
    if value == "" then return nil end
    local lower_value = value:lower()
    if lower_value:match("^hardcover[%w_-]*:") or lower_value:match("^isbn[%w_-]*:") then
        return value
    end

    local scheme = _attr(attrs, "opf:scheme") or _attr(attrs, "scheme")
    if not scheme or scheme == "" then return nil end
    scheme = scheme:lower():gsub("_", "-")
    if scheme == "hardcover" or scheme == "hardcover-slug" then
        return "hardcover:" .. value
    elseif scheme == "hardcover-id" or scheme == "hardcover-book-id" then
        return "hardcover-id:" .. value
    elseif scheme == "hardcover-edition" or scheme == "hardcover-edition-id" then
        return "hardcover-edition:" .. value
    elseif scheme == "isbn" or scheme == "isbn10" or scheme == "isbn-10" then
        return "isbn:" .. value
    elseif scheme == "isbn13" or scheme == "isbn-13" then
        return "isbn13:" .. value
    end
    return nil
end

local function _extractIdentifiersFromOpf(opf)
    if type(opf) ~= "string" or opf == "" then return nil end
    local tokens, seen = {}, {}
    local function add(token)
        if token and token ~= "" and not seen[token] then
            seen[token] = true
            tokens[#tokens + 1] = token
        end
    end
    for attrs, value in opf:gmatch("<%s*[%w_%-:]*identifier([^>]*)>(.-)</%s*[%w_%-:]*identifier%s*>") do
        add(_normaliseIdentifierToken(attrs, value))
    end
    for token in opf:gmatch("[Hh][Aa][Rr][Dd][Cc][Oo][Vv][Ee][Rr][%w_-]*%s*:%s*[%w_-]+") do
        add(token:gsub("%s*:%s*", ":"))
    end
    return #tokens > 0 and table.concat(tokens, "\n") or nil
end

local function _readEmbeddedIdentifiersFromEpub(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then return nil end

    local list_cmd = "unzip -lqq " .. _shellQuote(filepath) .. " '*.opf'"
    local fh = io.popen(list_cmd, "r")
    if not fh then return nil end
    local opf_path
    for line in fh:lines() do
        opf_path = line:match("%s+%d+%s+%S+%s+%S+%s+(.+%.opf)$")
                or line:match("([^%s].-%.opf)$")
        if opf_path then break end
    end
    fh:close()
    if not opf_path then return nil end

    local read_cmd = "unzip -p " .. _shellQuote(filepath) .. " " .. _shellQuote(opf_path)
    local opf_fh = io.popen(read_cmd, "r")
    if not opf_fh then return nil end
    local chunks, total = {}, 0
    for chunk in opf_fh:lines() do
        total = total + #chunk
        if total > 1024 * 1024 then break end
        chunks[#chunks + 1] = chunk
    end
    opf_fh:close()
    return _extractIdentifiersFromOpf(table.concat(chunks, "\n"))
end

local function _loadPickerModules()
    local ok_api, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok_api or not Api then
        return nil, "Hardcover API module could not be loaded"
    end
    local ok_user, User = pcall(require, "hardcover/lib/user")
    if not ok_user or not User then
        return nil, "Hardcover user module could not be loaded"
    end
    local ok_dm, DialogManager = pcall(require, "hardcover/lib/ui/dialog_manager")
    if not ok_dm or not DialogManager then
        return nil, "Hardcover dialog module could not be loaded"
    end
    local ok_book, Book = pcall(require, "hardcover/lib/book")
    if not ok_book then Book = nil end
    return {
        Api = Api,
        User = User,
        DialogManager = DialogManager,
        Book = Book,
    }
end

local function _openHardcoverSettingsObject()
    if _hc_settings_object then return _hc_settings_object end
    local ok, HardcoverSettings = pcall(require, "hardcover/lib/hardcover_settings")
    if not ok or not HardcoverSettings or type(HardcoverSettings.new) ~= "function" then
        return nil, "Hardcover settings module could not be loaded"
    end
    local ok_obj, obj = pcall(function()
        return HardcoverSettings:new(_settingsPath(), { document = { file = nil } })
    end)
    if not ok_obj or not obj then
        return nil, "Could not open Hardcover settings"
    end
    _hc_settings_object = obj
    return _hc_settings_object
end

local function _openPickerContext()
    local modules, mod_err = _loadPickerModules()
    if not modules then return nil, nil, nil, mod_err end
    local settings, settings_err = _openHardcoverSettingsObject()
    if not settings then return nil, nil, nil, settings_err end
    modules.User.settings = settings
    local ok_user, user_id = pcall(modules.User.getId, modules.User)
    if not ok_user or not user_id then
        return nil, nil, nil, "Could not fetch Hardcover user id"
    end
    return modules, settings, user_id
end

local function _linkPayload(hc_book, Book)
    local delete = {}
    local function field(name, value)
        if value == nil then delete[#delete + 1] = name end
        return value
    end
    local book_id = hc_book.book_id or hc_book.id
    local edition_id = hc_book.edition_id
    local edition_format = hc_book.edition_format or hc_book.filetype
    if Book and type(Book.editionFormatName) == "function" then
        edition_format = Book:editionFormatName(hc_book.edition_format, hc_book.reading_format_id)
                      or edition_format
    end
    return {
        book_id        = field("book_id", book_id),
        edition_id     = field("edition_id", edition_id),
        edition_format = field("edition_format", edition_format),
        pages          = field("pages", hc_book.pages),
        title          = field("title", hc_book.title),
        _delete        = delete,
    }
end

local function _applyExternalBookSetting(settings, filepath, config)
    if not settings then return nil end
    local books = settings:readSetting("books") or {}
    books[filepath] = books[filepath] or {}
    local book_setting = books[filepath]
    local original = _shallowCopy(book_setting)
    for k, v in pairs(config or {}) do
        if k == "_delete" then
            for _, name in ipairs(v) do
                book_setting[name] = nil
            end
        else
            book_setting[k] = v
        end
    end
    settings:saveSetting("books", books)
    settings:flush()
    return original
end

local function _notifyLoadedHardcoverSettings(filepath, config, original)
    local HardcoverSettings = package.loaded["hardcover/lib/hardcover_settings"]
    if not HardcoverSettings then return end
    if HardcoverSettings.settings and HardcoverSettings.settings ~= _hc_settings then
        pcall(_applyExternalBookSetting, HardcoverSettings.settings, filepath, config)
    end
    if type(HardcoverSettings.notify) == "function" then
        pcall(HardcoverSettings.notify, HardcoverSettings, "books", {
            filename = filepath,
            config = config,
        }, original or {})
    end
end

local function _mirrorExternalLink(filepath, config)
    local ok_settings, settings = pcall(_openExternalSettings)
    if not ok_settings or not settings then return end
    local original = _applyExternalBookSetting(settings, filepath, config)
    _notifyLoadedHardcoverSettings(filepath, config, original)
end

function Hardcover.invalidate()
    _links = nil
    _external_links = nil
    _enrichment_cache = nil
    _hc_settings = nil
    _hc_settings_object = nil
end

function Hardcover.clearEnrichmentCache()
    _saveEnrichmentCache({})
    local dir = _cacheDir()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.dir and lfs.attributes
            and lfs.attributes(dir, "mode") == "directory" then
        local ok_iter, iter, dir_obj = pcall(lfs.dir, dir)
        if ok_iter and type(iter) == "function" then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    pcall(os.remove, dir .. "/" .. entry)
                end
            end
        end
    end
end

function Hardcover.getLink(filepath)
    if not filepath then return nil end
    local link = _readLinks()[filepath]
    if type(link) == "table" and link.book_id then return link end
    link = _readExternalLinks(false)[filepath]
    return type(link) == "table" and link.book_id and link or nil
end

function Hardcover.linkBook(filepath, hc_book)
    if not (filepath and hc_book) then
        return false, "Missing book link data"
    end
    local modules = _loadPickerModules()
    local Book = modules and modules.Book or nil
    local payload = _linkPayload(hc_book, Book)
    if not payload.book_id then
        return false, "Missing Hardcover book id"
    end
    local links = _readLinks()
    links[filepath] = payload
    _saveLinks(links)
    pcall(_mirrorExternalLink, filepath, payload)
    Hardcover.invalidate()
    return true
end

function Hardcover.clearLink(filepath)
    if not filepath then return false, "Missing file path" end
    local links = _readLinks()
    links[filepath] = nil
    _saveLinks(links)
    pcall(_mirrorExternalLink, filepath, {
        _delete = { "book_id", "edition_id", "edition_format", "pages", "title" },
    })
    Hardcover.invalidate()
    return true
end

function Hardcover.linkLabel(filepath)
    local link = Hardcover.getLink(filepath)
    if not link or not link.book_id then return nil end
    local title = link.title or tostring(link.book_id)
    if link.edition_format and link.edition_format ~= "" then
        return title .. " · " .. link.edition_format
    end
    return title
end

function Hardcover.getEmbeddedIdentifiers(book)
    if type(book) ~= "table" then return nil end
    if type(book.identifiers) == "string" and book.identifiers ~= "" then
        return book.identifiers
    end
    if type(book.identifiers) == "table" then
        local parts = {}
        for k, v in pairs(book.identifiers) do
            if type(v) == "string" or type(v) == "number" then
                parts[#parts + 1] = tostring(k) .. ":" .. tostring(v)
            end
        end
        if #parts > 0 then
            book.identifiers = table.concat(parts, "\n")
            return book.identifiers
        end
    end
    local ok_epub_ids, ids = pcall(_readEmbeddedIdentifiersFromEpub, book.filepath)
    if not ok_epub_ids then ids = nil end
    if ids and ids ~= "" then
        book.identifiers = ids
        return ids
    end
    return nil
end

local function _parseHardcoverIdentifiers(modules, identifiers)
    if type(identifiers) ~= "string" or identifiers == "" then return nil end
    local parsed = {}
    if modules.Book and type(modules.Book.parseIdentifiers) == "function" then
        local ok, result = pcall(modules.Book.parseIdentifiers, modules.Book, identifiers)
        if ok and type(result) == "table" then parsed = result end
    end
    local lower = identifiers:lower()
    for line in lower:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([^:%s]+)%s*:%s*([^%s]+)")
        if key and value then
            key = key:gsub("_", "-")
            local digits = value:gsub("[^%dx]", "")
            if key == "hardcover" or key == "hardcover-slug" then
                parsed.book_slug = parsed.book_slug or value
            elseif key == "hardcover-edition" or key == "hardcover-edition-id"
                    or key == "hardcoveredition" or key == "hardcovereditionid" then
                parsed.edition_id = parsed.edition_id or digits
            elseif key == "isbn" or key == "isbn13" or key == "isbn-13"
                    or key == "isbn10" or key == "isbn-10" then
                if #digits == 13 then
                    parsed.isbn_13 = parsed.isbn_13 or digits
                elseif #digits == 10 then
                    parsed.isbn_10 = parsed.isbn_10 or digits
                end
            end
        end
    end
    parsed.book_id = parsed.book_id
        or lower:match("hardcover%-book%-id%s*:%s*(%d+)")
        or lower:match("hardcover%-id%s*:%s*(%d+)")
        or lower:match("hardcoverbookid%s*:%s*(%d+)")
        or lower:match("hardcoverid%s*:%s*(%d+)")
    return next(parsed) and parsed or nil
end

local function _lookupBookByIdentifiers(modules, parsed, user_id)
    if not parsed or not next(parsed) then return nil end
    local ok_lookup, book = pcall(function()
        return modules.Api:findBookByIdentifiers(parsed, user_id)
    end)
    return ok_lookup and book or nil
end

local function _findBookByIdentifiers(modules, identifiers, user_id)
    local parsed = _parseHardcoverIdentifiers(modules, identifiers)
    if not parsed then return nil end

    if parsed.edition_id then
        local book = _lookupBookByIdentifiers(modules, parsed, user_id)
        if book then return book end
    end

    -- ISBN usually resolves to the exact edition, while a Hardcover slug/id
    -- often resolves to the parent work. Prefer ISBN unless an explicit
    -- Hardcover edition id was embedded.
    if parsed.isbn_13 or parsed.isbn_10 then
        local isbn_only = {
            isbn_13 = parsed.isbn_13,
            isbn_10 = parsed.isbn_10,
        }
        local book = _lookupBookByIdentifiers(modules, isbn_only, user_id)
        if book then return book end
    end

    local book = _lookupBookByIdentifiers(modules, parsed, user_id)
    if book then return book end

    local numeric_id = parsed.book_id
    if not numeric_id and parsed.book_slug and tostring(parsed.book_slug):match("^%d+$") then
        numeric_id = parsed.book_slug
    end
    numeric_id = tonumber(numeric_id)
    if numeric_id and type(modules.Api.hydrateBooks) == "function" then
        local ok_hydrate, books = pcall(function()
            return modules.Api:hydrateBooks({ numeric_id }, user_id)
        end)
        if ok_hydrate and type(books) == "table" and books[1] then
            return books[1]
        end
    end
    return nil
end

local function _newDialogManager(modules, settings)
    modules.User.settings = settings
    return modules.DialogManager:new{ settings = settings }
end

function Hardcover.linkFromEmbeddedIdentifiers(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local identifiers = Hardcover.getEmbeddedIdentifiers(book)
    if not identifiers then return false, "No embedded Hardcover identifier found" end

    local modules, _settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local hc_book = _findBookByIdentifiers(modules, identifiers, user_id)
    if not hc_book then return false, "No Hardcover match found for embedded identifier" end

    local ok, link_err = Hardcover.linkBook(book.filepath, hc_book)
    if not ok then return false, link_err end
    if opts.on_linked then opts.on_linked(hc_book) end
    return true, hc_book
end

function Hardcover.showBookPicker(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local modules, settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local title = book.title or _filenameTitle(book.filepath)
    local author = _authorString(book)
    local books, err
    local embedded = _findBookByIdentifiers(modules, Hardcover.getEmbeddedIdentifiers(book), user_id)
    if embedded then
        books = { embedded }
    else
        books, err = modules.Api:findBooks(title, author, user_id)
    end
    if not books then return false, err or "No response from Hardcover" end

    local manager = _newDialogManager(modules, settings)
    manager:buildSearchDialog(
        "Select Hardcover book",
        books,
        { book_id = (Hardcover.getLink(book.filepath) or {}).book_id },
        function(selected)
            local ok, link_err = Hardcover.linkBook(book.filepath, selected)
            if not ok then
                if opts.on_error then opts.on_error(link_err) end
                return
            end
            local ok_refresh, refresh_err = Hardcover.refreshBook(book, { force = true })
            if opts.on_book_selected then
                opts.on_book_selected(selected, ok_refresh, refresh_err)
            end
        end,
        function(search)
            manager:updateSearchResults(search)
            return true
        end,
        title
    )
    return true
end

function Hardcover.showEditionPicker(book, book_id, opts)
    opts = opts or {}
    if not (book and book.filepath and book_id) then
        return false, "Missing Hardcover book id"
    end
    local modules, settings, user_id, ctx_err = _openPickerContext()
    if not modules then return false, ctx_err end
    local editions = modules.Api:findEditions(book_id, user_id)
    if not editions then return false, "Could not fetch Hardcover editions" end

    local link = Hardcover.getLink(book.filepath) or {}
    local manager = _newDialogManager(modules, settings)
    manager:buildSearchDialog(
        "Select Hardcover edition",
        editions,
        { edition_id = link.edition_id },
        function(selected)
            local ok, link_err = Hardcover.linkBook(book.filepath, selected)
            if not ok then
                if opts.on_error then opts.on_error(link_err) end
                return
            end
            local ok_refresh, refresh_err = Hardcover.refreshBook(book, { force = true })
            if opts.on_edition_selected then
                opts.on_edition_selected(selected, ok_refresh, refresh_err)
            end
        end
    )
    return true
end

local function _loadApi()
    local ok, Api = pcall(require, "hardcover/lib/hardcover_api")
    if not ok or not Api or type(Api.query) ~= "function" then
        return nil, "Hardcover plugin/API module could not be loaded"
    end
    return Api
end

local function _errString(err)
    if type(err) == "table" then
        if type(err.errors) == "table" and err.errors[1] then
            local first = err.errors[1]
            if type(first) == "table" and first.message then
                return tostring(first.message)
            end
            return tostring(first)
        end
        if err.error then return tostring(err.error) end
    end
    return tostring(err)
end

local function _imageUrl(row)
    if type(row) ~= "table" then return nil end
    if type(row.cached_image) == "string" and row.cached_image ~= "" then
        return row.cached_image
    end
    if type(row.image) == "table" and type(row.image.url) == "string" then
        return row.image.url
    end
    return nil
end

local function _downloadImage(url, key, force)
    if type(url) ~= "string" or url == "" or not key then return nil end
    local dir = _cacheDir()
    if not _ensureDir(dir) then return nil end
    local ext = url:match("%.([jJ][pP][eE]?[gG])[%?%#]?") and "jpg"
            or url:match("%.([pP][nN][gG])[%?%#]?") and "png"
            or "jpg"
    local safe_key = tostring(key):gsub("[^%w_.-]", "_")
    local path = dir .. "/" .. safe_key .. "." .. ext

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.attributes
            and lfs.attributes(path, "mode") == "file"
            and not force then
        return path
    end

    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"),
               require("ltn12"),
               require("socket"),
               require("socketutil")
    end)
    if not ok_require then return nil end

    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return nil end
    local ok_req, code = pcall(function()
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        local c = socket.skip(1, http.request({
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = "KOReader-Bookshelf" },
            sink = ltn12.sink.file(file),
            redirect = true,
        }))
        socketutil:reset_timeout()
        return c
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_req or code ~= 200 then
        pcall(os.remove, tmp)
        return nil
    end
    pcall(os.remove, path)
    local ok_rename = os.rename(tmp, path)
    if not ok_rename then
        pcall(os.remove, tmp)
        return nil
    end
    return path
end

local function _fetchBookEnrichment(book_id, edition_id, opts)
    opts = opts or {}
    local Api, api_err = _loadApi()
    if not Api then return false, api_err end
    book_id = tonumber(book_id) or book_id
    edition_id = tonumber(edition_id) or edition_id
    if not book_id then return false, "Missing Hardcover book id" end

    local data, err
    if edition_id then
        local query = [[
            query ($bookId: Int!, $editionId: Int!) {
              book: books_by_pk(id: $bookId) {
                id
                title
                description
                cached_image
              }
              edition: editions_by_pk(id: $editionId) {
                id
                title
                cached_image
              }
            }
        ]]
        local ok_query
        ok_query, data, err = pcall(Api.query, Api, query, {
            bookId = book_id,
            editionId = edition_id,
        })
        if not ok_query then
            return false, "Hardcover enrichment failed: " .. _errString(data)
        end
    else
        local query = [[
            query ($bookId: Int!) {
              book: books_by_pk(id: $bookId) {
                id
                title
                description
                cached_image
              }
            }
        ]]
        local ok_query
        ok_query, data, err = pcall(Api.query, Api, query, { bookId = book_id })
        if not ok_query then
            return false, "Hardcover enrichment failed: " .. _errString(data)
        end
    end
    if not data or type(data.book) ~= "table" then
        return false, err and ("Hardcover enrichment failed: " .. _errString(err))
            or "No response from Hardcover"
    end

    local edition = type(data.edition) == "table" and data.edition or nil
    local image_url = _imageUrl(edition) or _imageUrl(data.book)
    local key = _cacheKey(book_id, edition_id)
    local cover_path = image_url and _downloadImage(image_url, key, opts.force) or nil
    return true, {
        book_id = data.book.id or book_id,
        edition_id = edition and (edition.id or edition_id) or edition_id,
        title = (edition and edition.title) or data.book.title,
        description = data.book.description,
        cover_url = image_url,
        cover_path = cover_path,
        fetched_at = os.time(),
    }
end

function Hardcover.getCachedEnrichment(book_id, edition_id)
    local cache = _readEnrichmentCache()
    local key = _cacheKey(book_id, edition_id)
    local entry = key and cache[key] or nil
    if type(entry) == "table" then return entry end
    if edition_id then
        entry = cache[_cacheKey(book_id)]
        if type(entry) == "table" then return entry end
    end
    return nil
end

function Hardcover.refreshBook(book, opts)
    opts = opts or {}
    if not (book and book.filepath) then return false, "Missing local book" end
    local link = Hardcover.getLink(book.filepath)
    if not link or not link.book_id then return false, "Book is not linked to Hardcover" end
    local ok, payload = _fetchBookEnrichment(link.book_id, link.edition_id, opts)
    if not ok then return false, payload end
    local cache = _readEnrichmentCache()
    cache[_cacheKey(link.book_id, link.edition_id)] = payload
    _saveEnrichmentCache(cache)
    if opts.on_refreshed then opts.on_refreshed(payload) end
    return true, payload
end

function Hardcover.refreshAllLinked()
    local linked, updated, failed = 0, 0, 0
    local errors = {}
    local seen = {}
    local function process(_filepath, link)
        if type(link) ~= "table" or not link.book_id then return end
        local key = _cacheKey(link.book_id, link.edition_id)
        if seen[key] then return end
        seen[key] = true
        linked = linked + 1
        local ok, payload = _fetchBookEnrichment(link.book_id, link.edition_id, { force = true })
        if ok then
            local cache = _readEnrichmentCache()
            cache[key] = payload
            _saveEnrichmentCache(cache)
            updated = updated + 1
        else
            failed = failed + 1
            errors[#errors + 1] = tostring(payload)
        end
    end
    for fp, link in pairs(_readExternalLinks(true)) do process(fp, link) end
    for fp, link in pairs(_readLinks()) do process(fp, link) end
    return true, {
        linked = linked,
        updated = updated,
        failed = failed,
        errors = errors,
    }
end

function Hardcover.enrichBook(book)
    if not book or not book.filepath then return book end
    local link = Hardcover.getLink(book.filepath)
    if not link then return book end

    book.hardcover_book_id = tonumber(link.book_id) or link.book_id
    book.hardcover_edition_id = tonumber(link.edition_id) or link.edition_id
    book.hardcover_title = link.title

    local enrichment = Hardcover.getCachedEnrichment(link.book_id, link.edition_id)
    if type(enrichment) ~= "table" then return book end

    if BookshelfSettings.nilOrTrue("hardcover_fill_descriptions")
            and (not book.description or book.description == "")
            and type(enrichment.description) == "string"
            and enrichment.description ~= "" then
        book.description = enrichment.description
        book.hardcover_description = true
    end
    if BookshelfSettings.nilOrTrue("hardcover_fill_covers")
            and not book.has_cover
            and type(enrichment.cover_path) == "string"
            and enrichment.cover_path ~= "" then
        book.cover_image_path = enrichment.cover_path
        book.hardcover_cover = true
    end
    return book
end

return Hardcover
