-- tests/_test_image_probe.lua
-- ImageSource.probeSize: a cover's pixel dimensions read from the file header
-- rather than from a decoded bitmap.
--
-- Why it exists: the external-cover path has to decide whether the file can
-- give more detail than the slot already holds, and both alternatives are
-- expensive in the wrong way. Decoding to find out costs the decode the
-- question was about, and assuming it can costs an upscale through MuPDF,
-- which is the direction that corrupts on Kindle.
--
-- The headers are built byte by byte here rather than kept as fixture files:
-- what is being tested is the parse, and a checked-in JPEG would hide which
-- byte the answer came from.

package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- The module pulls in KOReader's renderer and settings at load; none of that
-- runs for a header read, so the stubs only have to exist.
package.loaded["ui/renderimage"] = { renderImageFile = function() return nil end }
package.loaded["logger"] = { dbg = function() end, info = function() end,
                             warn = function() end, err = function() end }
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(_k, d) return d end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}
_G.G_reader_settings = _G.G_reader_settings or {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}

-- A real filesystem is the honest fixture here: probeSize opens the file and
-- stats it for the memo key.
local TMP = os.getenv("TMPDIR") or "/tmp"
local made = {}
local function write_file(name, bytes)
    local path = TMP .. "/bookshelf_probe_" .. name
    local f = assert(io.open(path, "wb"))
    f:write(bytes)
    f:close()
    made[#made + 1] = path
    return path
end

package.loaded["libs/libkoreader-lfs"] = {
    -- Existence without io.open: the memo test counts the probe's own reads,
    -- and a stub that opened the file would be counted as one of them.
    attributes = function(path, key)
        if not os.rename(path, path) then return nil end
        local a = { mode = "file", modification = 1000 }
        if key then return a[key] end
        return a
    end,
    dir = function() return function() return nil end end,
}

local ImageSource = dofile("lib/bookshelf_image_source.lua")

local function be32(n)
    return string.char(math.floor(n / 16777216) % 256,
                       math.floor(n / 65536) % 256,
                       math.floor(n / 256) % 256,
                       n % 256)
end
local function be16(n)
    return string.char(math.floor(n / 256) % 256, n % 256)
end

local function png(w, h)
    return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(w) .. be32(h)
           .. string.rep("\0", 40)
end

-- marker: the SOF byte. segments: raw bytes inserted before the frame header.
local function jpeg(w, h, marker, segments)
    local sof = string.char(0xFF, marker or 0xC0)
        .. be16(8 + 3)          -- length: itself + precision + dims + 1 comp
        .. string.char(8)       -- sample precision
        .. be16(h) .. be16(w)
        .. string.char(1, 1, 0x11, 0)
    return string.char(0xFF, 0xD8) .. (segments or "") .. sof
           .. string.rep("\0", 32)
end

local function app_segment(marker, payload)
    return string.char(0xFF, marker) .. be16(#payload + 2) .. payload
end

t.test("PNG dimensions come from the IHDR chunk", function()
    local w, h = ImageSource.probeSize(write_file("a.png", png(1072, 1448)))
    eq(w, 1072); eq(h, 1448)
end)

t.test("baseline JPEG dimensions come from the frame header", function()
    local w, h = ImageSource.probeSize(write_file("a.jpg", jpeg(600, 900)))
    eq(w, 600); eq(h, 900)
end)

t.test("height comes before width in a JPEG frame header", function()
    -- The one easy way to get this backwards, and a square test image would
    -- never catch it.
    local w, h = ImageSource.probeSize(write_file("tall.jpg", jpeg(400, 1600)))
    eq(w, 400, "width"); eq(h, 1600, "height")
end)

t.test("segments before the frame header are skipped by their length", function()
    -- A cover from a phone or a download service carries EXIF, and often an
    -- ICC profile and a comment as well.
    local pre = app_segment(0xE0, "JFIF\0" .. string.rep("\1", 12))
        .. app_segment(0xE1, "Exif\0\0" .. string.rep("\7", 200))
        .. app_segment(0xE2, "ICC_PROFILE\0" .. string.rep("\3", 300))
        .. app_segment(0xFE, "a comment")
    local w, h = ImageSource.probeSize(write_file("exif.jpg", jpeg(300, 450, 0xC0, pre)))
    eq(w, 300); eq(h, 450)
end)

t.test("a Huffman table is not mistaken for a frame header", function()
    -- 0xC4 sits inside the C0..CF range but is a table, not a picture. Reading
    -- it as one yields whatever the table's first bytes happen to say.
    local pre = app_segment(0xC4, string.rep("\5", 60))
    local w, h = ImageSource.probeSize(write_file("dht.jpg", jpeg(210, 320, 0xC0, pre)))
    eq(w, 210); eq(h, 320)
end)

t.test("progressive JPEGs are read too", function()
    -- 0xC2 rather than 0xC0; the frame header has the same shape.
    local w, h = ImageSource.probeSize(write_file("prog.jpg", jpeg(512, 768, 0xC2)))
    eq(w, 512); eq(h, 768)
end)

t.test("anything unreadable answers nil rather than a guess", function()
    -- nil means "ask the decoder", which is what the callers did before, so a
    -- wrong answer is far worse than no answer.
    assert(not ImageSource.probeSize(write_file("text.txt", string.rep("not an image", 20))),
        "plain text")
    assert(not ImageSource.probeSize(write_file("short.png", "\137PNG\r\n\26\n" .. "xx")),
        "a truncated header")
    assert(not ImageSource.probeSize(write_file("nosof.jpg",
            string.char(0xFF, 0xD8) .. app_segment(0xE1, string.rep("\9", 500)))),
        "a JPEG with no frame header in the window")
    assert(not ImageSource.probeSize(TMP .. "/bookshelf_probe_does_not_exist"),
        "a missing file")
    assert(not ImageSource.probeSize(nil), "no path at all")
end)

t.test("the answer is memoised per file", function()
    -- The shelf asks about the same cover on every render. Counted by reads
    -- rather than by deleting the file: the memo key carries the file's mtime,
    -- so a stat happens either way and only the READ is worth saving.
    local path = write_file("memo.png", png(800, 1200))
    local real_open, opens = io.open, 0
    io.open = function(...) opens = opens + 1; return real_open(...) end
    local w1, h1 = ImageSource.probeSize(path)
    local w2, h2 = ImageSource.probeSize(path)
    io.open = real_open
    eq(w1, 800); eq(h1, 1200)
    eq(w2, 800, "same answer"); eq(h2, 1200)
    eq(opens, 1, "the file is read once, not once per render")
end)

for _i, path in ipairs(made) do os.remove(path) end

t.done()
