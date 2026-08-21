-- tests/_test_epub_metadata.lua
-- Pure-Lua tests for EPUB OPF creator-role, subtitle, and illustrator parsing.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(_fp, key)
        if key == nil then return { modification = 1, size = 1 } end
        if key == "modification" then return 1 end
        if key == "size" then return 1 end
    end,
}

local EpubMetadata = dofile("lib/bookshelf_epub_metadata.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end

local function eq(actual, expected)
    assert(actual == expected, "expected " .. tostring(expected) .. " got " .. tostring(actual))
end

test("extractAuthorCreatorsFromOpf: ignores translator and keeps role=aut", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                  xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:creator opf:file-as="Alsberg, Rebecca" opf:role="trl">Rebecca Alsberg</dc:creator>
            <dc:creator opf:file-as="Ove Knausgård, Karl" opf:role="aut">Karl Ove Knausgård</dc:creator>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors and #authors == 1, "expected one author")
    eq(authors[1], "Karl Ove Knausgård")
end)

test("extractAuthorCreatorsFromOpf: supports EPUB3 refined role metadata", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:creator id="c1">Rebecca Alsberg</dc:creator>
            <meta refines="#c1" property="role" scheme="marc:relators">trl</meta>
            <dc:creator id="c2">Karl Ove Knausgård</dc:creator>
            <meta refines="#c2" property="role" scheme="marc:relators">aut</meta>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors and #authors == 1, "expected one author")
    eq(authors[1], "Karl Ove Knausgård")
end)

test("extractAuthorCreatorsFromOpf: returns nil when creators have no author role", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"
                  xmlns:opf="http://www.idpf.org/2007/opf">
            <dc:creator opf:role="trl">Translator Only</dc:creator>
            <dc:creator>Unspecified Creator</dc:creator>
        </metadata>
    ]]
    local authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    assert(authors == nil, "expected nil fallback")
end)

test("extractSubtitleFromOpf: reads EPUB3 title-type subtitle", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title id="t-main">Demon Slayer: Kimetsu No Yaiba, Vol. 8</dc:title>
            <meta refines="#t-main" property="title-type">main</meta>
            <dc:title id="t-sub">The Strength of the Hashira</dc:title>
            <meta refines="#t-sub" property="title-type">subtitle</meta>
        </metadata>
    ]]
    eq(EpubMetadata.extractSubtitleFromOpf(opf), "The Strength of the Hashira")
end)

test("extractSubtitleFromOpf: supports BookOrbit custom meta fallback", function()
    local opf = [[
        <metadata>
            <meta name="bookorbit:subtitle" content="A Custom Subtitle" />
        </metadata>
    ]]
    eq(EpubMetadata.extractSubtitleFromOpf(opf), "A Custom Subtitle")
end)

test("extractSubtitleFromOpf: does not guess from an untyped second title", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Main title</dc:title>
            <dc:title>Ambiguous alternate title</dc:title>
        </metadata>
    ]]
    assert(EpubMetadata.extractSubtitleFromOpf(opf) == nil, "expected nil")
end)

test("extractIllustratorFromOpf: reads BookOrbit custom metadata", function()
    local opf = [[
        <metadata>
            <meta property="bookorbit:custom:illustrator">Masayuki Taguchi</meta>
        </metadata>
    ]]
    eq(EpubMetadata.extractIllustratorFromOpf(opf), "Masayuki Taguchi")
end)

test("extractIllustratorFromOpf: supports EPUB3 refined contributor role", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:contributor id="c1">Standard Illustrator</dc:contributor>
            <meta refines="#c1" property="role" scheme="marc:relators">ill</meta>
        </metadata>
    ]]
    eq(EpubMetadata.extractIllustratorFromOpf(opf), "Standard Illustrator")
end)

test("extractTranslatorFromOpf: reads BookOrbit custom metadata", function()
    local opf = [[
        <metadata>
            <meta property="bookorbit:custom:translator">Susanne Widén</meta>
        </metadata>
    ]]
    eq(EpubMetadata.extractTranslatorFromOpf(opf), "Susanne Widén")
end)

test("extractTranslatorFromOpf: supports EPUB3 refined contributor role", function()
    local opf = [[
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:contributor id="c1">Standard Translator</dc:contributor>
            <meta refines="#c1" property="role" scheme="marc:relators">trl</meta>
        </metadata>
    ]]
    eq(EpubMetadata.extractTranslatorFromOpf(opf), "Standard Translator")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
