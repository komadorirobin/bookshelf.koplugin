-- tests/_test_i18n_sv.lua

package.loaded["logger"] = { dbg = function() end }
package.loaded["gettext"] = function(text) return "KOReader: " .. text end

G_reader_settings = {
    readSetting = function(_, key)
        if key == "language" then return "sv_SE" end
    end,
}

local I18n = dofile("lib/bookshelf_i18n.lua")

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

test("loads Swedish locale through sv_SE fallback", function()
    assert(I18n.gettext("Authors") == "Författare")
    assert(I18n.gettext("Latest") == "Senaste")
    assert(I18n.gettext("Next") == "Nästa")
end)

test("translates reading states and settings", function()
    assert(I18n.gettext("Reading") == "Pågående")
    assert(I18n.gettext("Finished") == "Färdiglästa")
    assert(I18n.gettext("Shelf size") == "Biblioteksöversikt")
end)

test("fixed SimpleUI profiles expose translated labels", function()
    package.loaded["lib/bookshelf_i18n"] = I18n
    local Profiles = dofile("lib/bookshelf_profiles.lua")
    local prose = Profiles.get("prose")
    local comics = Profiles.get("comics")
    assert(prose.label == "Böcker")
    assert(prose.chips[4].label == "Författare")
    assert(prose.chips[5].label == "Senaste")
    assert(comics.label == "Manga och serier")
    assert(comics.chips[3].label == "Nästa")
end)

test("falls back to KOReader for untranslated strings", function()
    assert(I18n.gettext("Not in the Bookshelf catalogue") ==
        "KOReader: Not in the Bookshelf catalogue")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
