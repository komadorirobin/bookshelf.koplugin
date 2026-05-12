-- tests/_test_profiles.lua

local Profiles = dofile("bookshelf_profiles.lua")

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

test("matchFile: prose roots map to prose profile", function()
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Fiktion/book.epub") == "prose")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Facklitteratur/book.epub") == "prose")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Lyrik/book.epub") == "prose")
end)

test("matchFile: comics roots map to comics profile", function()
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Manga/Attack on Titan/01.cbz") == "comics")
    assert(Profiles.matchFile("/storage/emulated/0/ePubs/Serier/album.cbz") == "comics")
end)

test("matchFile: unknown paths have no profile match", function()
    assert(Profiles.matchFile("/storage/emulated/0/Downloads/book.epub") == nil)
    assert(Profiles.matchFile(nil) == nil)
end)

test("folderSort: prose defaults to author and comics defaults to series", function()
    _G.G_reader_settings = nil
    assert(Profiles.folderSort(Profiles.get("prose")) == "author")
    assert(Profiles.folderSort(Profiles.get("comics")) == "series")
end)

test("folderSort: saved profile sort overrides default when valid", function()
    _G.G_reader_settings = {
        readSetting = function(_, key)
            if key == "bookshelf_profile_sort_prose" then return "last_read" end
        end,
    }
    assert(Profiles.folderSort(Profiles.get("prose")) == "last_read")
end)

test("folderSort: invalid saved profile sort falls back to default", function()
    _G.G_reader_settings = {
        readSetting = function(_, key)
            if key == "bookshelf_profile_sort_prose" then return "garbage" end
        end,
    }
    assert(Profiles.folderSort(Profiles.get("prose")) == "author")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
