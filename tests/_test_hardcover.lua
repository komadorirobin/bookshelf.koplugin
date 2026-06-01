-- tests/_test_hardcover.lua
-- Pure-Lua tests for Bookshelf's optional Hardcover enrichment cache.

package.path = "./?.lua;./?/init.lua;" .. package.path

local settings = {}

package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key, default)
        local v = settings["bookshelf_" .. key]
        if v == nil then return default end
        return v
    end,
    save = function(key, value)
        settings["bookshelf_" .. key] = value
    end,
    delete = function(key)
        settings["bookshelf_" .. key] = nil
    end,
    flush = function() end,
    isTrue = function(key)
        return settings["bookshelf_" .. key] == true
    end,
    nilOrTrue = function(key)
        local v = settings["bookshelf_" .. key]
        return v == nil or v == true
    end,
}

package.loaded["datastorage"] = {
    getSettingsDir = function() return "/tmp/bookshelf-hardcover-test" end,
}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function() return nil end,
}

package.loaded["hardcover/lib/hardcover_api"] = {
    query = function(_self, _query, variables)
        return {
            book = {
                id = variables.bookId,
                title = "Fresh Hardcover Title",
                description = "Fresh Hardcover description.",
            },
        }
    end,
}

local Hardcover = dofile("lib/bookshelf_hardcover.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function reset()
    settings = {}
    Hardcover.invalidate()
end

test("linkBook stores a Bookshelf-owned link", function()
    reset()
    local ok, err = Hardcover.linkBook("/books/a.epub", {
        id = 123,
        title = "A Book",
    })
    assert(ok, tostring(err))
    local link = Hardcover.getLink("/books/a.epub")
    assert(link and link.book_id == 123, "missing book_id")
    assert(link.title == "A Book", "missing title")
end)

test("enrichBook fills only missing description and missing cover", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))
    settings.bookshelf_hardcover_enrichment = {
        ["123"] = {
            description = "Cached description.",
            cover_path = "/tmp/cached-cover.jpg",
        },
    }
    Hardcover.invalidate()

    local book = Hardcover.enrichBook{
        filepath = "/books/a.epub",
        title = "A Book",
        has_cover = false,
    }
    assert(book.description == "Cached description.", tostring(book.description))
    assert(book.cover_image_path == "/tmp/cached-cover.jpg", tostring(book.cover_image_path))
    assert(book.hardcover_description == true, "description marker missing")
    assert(book.hardcover_cover == true, "cover marker missing")

    local preserved = Hardcover.enrichBook{
        filepath = "/books/a.epub",
        description = "Local description.",
        has_cover = true,
    }
    assert(preserved.description == "Local description.", "overwrote local description")
    assert(preserved.cover_image_path == nil, "overwrote local cover")
end)

test("refreshBook writes cache from Hardcover API", function()
    reset()
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))
    local ok, payload = Hardcover.refreshBook{ filepath = "/books/a.epub" }
    assert(ok, tostring(payload))
    assert(payload.description == "Fresh Hardcover description.", "bad payload")

    local book = Hardcover.enrichBook{ filepath = "/books/a.epub", has_cover = false }
    assert(book.description == "Fresh Hardcover description.", tostring(book.description))
end)

test("refreshBookOnline uses KOReader network manager when available", function()
    reset()
    local network_called = false
    package.loaded["ui/network/manager"] = {
        runWhenOnline = function(_self, callback)
            network_called = true
            callback()
        end,
    }
    assert(Hardcover.linkBook("/books/a.epub", { id = 123, title = "A Book" }))

    local callback_ok, callback_payload
    local ok = Hardcover.refreshBookOnline({ filepath = "/books/a.epub" }, {}, function(refresh_ok, payload)
        callback_ok = refresh_ok
        callback_payload = payload
    end)
    assert(ok == true, "online wrapper did not return true")
    assert(network_called == true, "NetworkMgr:runWhenOnline was not used")
    assert(callback_ok == true, tostring(callback_payload))
    assert(callback_payload.description == "Fresh Hardcover description.", "bad callback payload")
    package.loaded["ui/network/manager"] = nil
end)

io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
if fail > 0 then os.exit(1) end
