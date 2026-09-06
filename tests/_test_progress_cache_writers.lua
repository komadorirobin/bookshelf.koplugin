-- tests/_test_progress_cache_writers.lua
-- The progress cache has exactly ONE writer, so its two callers cannot fill
-- different field sets.
--
-- Usage (from plugin root): lua tests/_test_progress_cache_writers.lua
--
-- SOURCE-SHAPE, because the failure is about which code path wrote an entry and
-- nothing about a returned value reports that.
--
-- WHAT HAPPENED. readProgress fills the cache from the sidecar; buildBook seeds
-- it from the handle it already has open, so a readProgress that follows is a
-- table lookup instead of a second parse. Both wrote the table inline, and the
-- comment over buildBook's copy asked the next person to keep the two in step.
--
-- Adding page_num to readProgress alone was enough to break it. Every reader
-- takes the cached entry wholesale, so tapping a book -- which builds the
-- hero's record through buildBook -- replaced a complete entry with one missing
-- that field, and %page_num disappeared from the shelf row it had just started
-- working on. Caught within minutes on device, by the maintainer, not by a
-- test: nothing failed, a token simply went quiet.
--
-- A promise in a comment is what did not hold. This asserts the structure.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local src = {}
for line in io.lines("lib/bookshelf_book_repository.lua") do
    if not line:match("^%s*%-%-") then src[#src + 1] = line end
end
src = table.concat(src, "\n")

t.test("only one place writes the cache table", function()
    local n = select(2, src:gsub("_progress_cache%[filepath%]%s*=%s*{", ""))
    eq(n, 1, "a second inline writer is back; it will drift from the first")
end)

t.test("that writer is the shared helper", function()
    local body = src:match("local function _writeProgressCache%b()(.-)\nend\n")
    assert(body, "_writeProgressCache is gone or was renamed")
    assert(body:match("_progress_cache%[filepath%]"),
        "the helper no longer writes the cache")
end)

t.test("both callers go through it", function()
    -- readProgress and buildBook. Two call sites plus the definition.
    local n = select(2, src:gsub("_writeProgressCache%(", ""))
    assert(n >= 3, "expected the definition and two callers, found " .. n)
end)

t.test("the helper carries every field a reader takes", function()
    -- Readers destructure the entry wholesale, so a field the helper omits is
    -- a field that silently becomes nil for whichever caller wrote last.
    local body = src:match("local function _writeProgressCache%b()(.-)\nend\n")
    for _i, f in ipairs({ "pct", "status", "rating", "page_count", "page_num",
                          "expires_at" }) do
        assert(body:match(f .. "%s*="), "the cache no longer stores " .. f)
    end
end)

t.test("readProgress hands page_num back to its callers", function()
    -- The adapter's fillProgress reads it off progressFor's returns; a cache
    -- that stores it but a function that does not return it would be the same
    -- bug one layer up.
    local body = src:match("function Repo%.readProgress%b()(.-)\nend\n")
    assert(body, "Repo.readProgress is gone or was renamed")
    assert(body:match("return pct, status, rating, page_count, page_num"),
        "readProgress no longer returns page_num")
    assert(body:match("cached%.page_num"),
        "the cache-hit path drops page_num, so it is nil for 2 minutes "
        .. "after any read that populated the entry")
end)

-- ── One precedence, two functions ─────────────────────────────────────────

t.test("buildBook does not take last_page before the pagemap label", function()
    -- The scales differ. page_count prefers pagemap_doc_pages, the stable
    -- publisher pagination; last_page is crengine's rendered page index at the
    -- reader's current font size. Same book, different rulers -- the hazard
    -- this file already documents for pages-left (#38).
    --
    -- buildBook used to assign page_num from last_page unconditionally, before
    -- the block that claims to decide precedence, so last_page silently won
    -- and a finished book reported page 568 OF 567. readProgress had always
    -- preferred the label, so the hero and the shelf row disagreed about the
    -- same book as soon as %page_num started rendering on rows.
    assert(not src:match("book%.page_num%s*=%s*ds:readSetting%(\"last_page\"%)"),
        "last_page is assigned straight to page_num again, ahead of the label")
    assert(src:match("local ds_last_page%s*=%s*ds:readSetting%(\"last_page\"%)"),
        "last_page is no longer read for the precedence block to use")
end)

t.test("both functions round the synthesised page the same way", function()
    -- The last rung is a fraction of the count, and truncating in one place
    -- while rounding in the other makes the two differ by one on a book that
    -- is 99.9% read -- which is most of a finished book's life on screen.
    local n = select(2, src:gsub("%+%s*0%.5", ""))
    assert(n >= 2, "the two page_num derivations no longer round alike")
end)

t.done()
