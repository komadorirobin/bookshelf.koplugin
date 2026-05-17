-- tests/_test_text_segments.lua
-- Pure-Lua unit tests for bookshelf_text_segments.lua.

package.path = "./?.lua;./?/init.lua;" .. package.path

local Segments = dofile("lib/bookshelf_text_segments.lua")

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

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "") .. " expected=" .. tostring(expected) .. " got=" .. tostring(actual), 2)
    end
end

local function classes(label)
    local out = {}
    for _, seg in ipairs(Segments.labelSegments(label)) do
        out[#out + 1] = seg.class .. ":" .. seg.text
    end
    return table.concat(out, "|")
end

test("latin-1 letters stay text", function()
    eq(classes("Drömräkning"), "text:Drömräkning")
    eq(classes("ÅÄÖ åäö"), "text:ÅÄÖ åäö")
end)

test("non-latin titles stay text", function()
    eq(classes("進撃の巨人"), "text:進撃の巨人")
end)

test("private-use nerd font glyphs are icons", function()
    eq(classes("Manga \239\128\130"), "text:Manga |icon:\239\128\130")
end)

test("emoji and dingbats are icons", function()
    eq(classes("Done ✓"), "text:Done |icon:✓")
    eq(classes("Smile 😀"), "text:Smile |icon:😀")
end)

print(string.format("\ntext_segments: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
