-- Pure-Lua tests for display-only folder name cleanup.

local FolderLabel = dofile("lib/bookshelf_folder_label.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(actual, expected)
    assert(actual == expected,
        "expected " .. tostring(expected) .. " got " .. tostring(actual))
end

test("display: replaces a title separator underscore with a colon", function()
    eq(FolderLabel.display("Demon Slayer_ Kimetsu no Yaiba"),
        "Demon Slayer: Kimetsu no Yaiba")
end)

test("display: preserves an internal underscore without following space", function()
    eq(FolderLabel.display("Akira_6 Volumes"), "Akira_6 Volumes")
end)

test("display: restores calibre-style trailing English articles", function()
    eq(FolderLabel.display("Locked Tomb, The"), "The Locked Tomb")
    eq(FolderLabel.display("Somewhere, An"), "An Somewhere")
    eq(FolderLabel.display("Beginning, A"), "A Beginning")
    eq(FolderLabel.display("Smith, A."), "Smith, A.")
end)

test("display: preserves ordinary names and non-strings", function()
    eq(FolderLabel.display("Fiktion"), "Fiktion")
    eq(FolderLabel.display(nil), nil)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
