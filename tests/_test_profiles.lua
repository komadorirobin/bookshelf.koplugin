-- tests/_test_profiles.lua

local saved_settings = {}
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(key) return saved_settings[key] end,
    save = function(key, value) saved_settings[key] = value end,
    delete = function(key) saved_settings[key] = nil end,
    flush = function() end,
}

local Profiles = dofile("lib/bookshelf_profiles.lua")

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

test("locationForFile: prose root file selects its folder chip", function()
    local loc = Profiles.locationForFile(
        "/storage/emulated/0/ePubs/Fiktion/book.epub")
    assert(loc and loc.profile_key == "prose")
    assert(loc.chip_key == "profile_fiction")
    assert(loc.root == "/storage/emulated/0/ePubs/Fiktion")
    assert(loc.folder == loc.root)
end)

test("locationForFile: nested manga selects the series folder", function()
    local loc = Profiles.locationForFile(
        "/storage/emulated/0/ePubs/Manga/Attack on Titan/31.cbz")
    assert(loc and loc.profile_key == "comics")
    assert(loc.chip_key == "profile_manga")
    assert(loc.root == "/storage/emulated/0/ePubs/Manga")
    assert(loc.folder == "/storage/emulated/0/ePubs/Manga/Attack on Titan")
end)

test("locationForFile: unknown paths have no location", function()
    assert(Profiles.locationForFile("/storage/emulated/0/Downloads/book.epub") == nil)
    assert(Profiles.locationForFile(nil) == nil)
end)

test("folderSortPriority: prose defaults to author surname and comics defaults to series", function()
    assert(Profiles.folderSortPriority(Profiles.get("prose"))[1].key == "author_surname")
    assert(Profiles.folderSortPriority(Profiles.get("comics"))[1].key == "series_name")
end)

test("scope: profile roots are exposed for repository scoping", function()
    local scope = Profiles.scope(Profiles.get("prose"))
    assert(scope and scope.roots and #scope.roots == 3)
end)

test("profiles: both expose a short BookOrbit TBR chip", function()
    local prose = Profiles.chip(Profiles.get("prose"), "bookorbit_tbr")
    local comics = Profiles.chip(Profiles.get("comics"), "bookorbit_tbr")
    assert(prose and prose.label == "TBR" and prose.kind == "bookorbit_want")
    assert(comics and comics.label == "TBR" and comics.kind == "bookorbit_want")
end)

test("profile shelf settings are isolated per profile and chip", function()
    local prose = Profiles.get("prose")
    local comics = Profiles.get("comics")
    Profiles.saveShelfSettings(prose, "profile_fiction", {
        view_mode = "list",
        list_rows = 5,
    })
    Profiles.saveShelfSettings(comics, "profile_manga", {
        view_mode = "spines",
        spine_rows = 3,
    })
    local fiction = Profiles.shelfSettings(prose, "profile_fiction")
    local manga = Profiles.shelfSettings(comics, "profile_manga")
    assert(fiction.view_mode == "list" and fiction.list_rows == 5)
    assert(fiction.spine_rows == nil)
    assert(manga.view_mode == "spines" and manga.spine_rows == 3)
    assert(Profiles.shelfSettings(prose, "profile_nonfiction").view_mode == nil)
end)

test("profile shelf settings preserve false and discard unrelated fields", function()
    local comics = Profiles.get("comics")
    Profiles.saveShelfSettings(comics, "profile_comics", {
        view_mode = "spines",
        spine_face_out = false,
        spine_show_author = false,
        label = "must not replace a fixed profile label",
    })
    local got = Profiles.shelfSettings(comics, "profile_comics")
    assert(got.view_mode == "spines")
    assert(got.spine_face_out == false)
    assert(got.spine_show_author == false)
    assert(got.label == nil)
end)

test("saving an empty profile shelf setting clears its override", function()
    local prose = Profiles.get("prose")
    Profiles.saveShelfSettings(prose, "profile_poetry", { view_mode = "covers" })
    assert(Profiles.shelfSettings(prose, "profile_poetry").view_mode == "covers")
    Profiles.saveShelfSettings(prose, "profile_poetry", {})
    assert(next(Profiles.shelfSettings(prose, "profile_poetry")) == nil)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
