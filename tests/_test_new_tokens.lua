-- tests/_test_new_tokens.lua
-- The tokens added for issues 298 and 333: SSH status, and the page and
-- chapter of the quote %quote picked.
--
-- Usage (from plugin root): lua tests/_test_new_tokens.lua
--
-- All five are pure catalogue-plus-expander additions with no UI of their own,
-- so what needs pinning is not layout but three quieter contracts:
--
--   * every catalogue entry has a working expander behind it. A token that
--     lists in the picker and renders as its own literal text is worse than an
--     absent one -- the reader inserts it, sees "%quote_page" on their shelf,
--     and files a bug.
--   * %quote_page and %quote_chapter describe the SAME highlight %quote chose.
--     Quotes.forBook re-rolls a random pick per key, so three tokens each
--     calling it independently would attribute one quote to another's page.

package.path = "./?.lua;./?/init.lua;" .. package.path
package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(_f, s) return tostring(s or "") end,
}
local _i18n = { gettext = function(t) return t end,
                ngettext = function(s, p, n) return n == 1 and s or p end }
package.loaded["bookshelf_i18n"] = _i18n
package.loaded["lib/bookshelf_i18n"] = _i18n

-- The SSH plugin, present or absent, is the whole input to the ssh tokens.
local _ssh_running, _ssh_present = false, true
package.loaded["pluginloader"] = {
    enabled_plugins = setmetatable({}, { __index = function(_, k)
        if k == 1 and _ssh_present then
            return { name = "SSH", isRunning = function() return _ssh_running end }
        end
        return nil
    end }),
}

-- Quotes: one book, two highlights, so a re-rolling pick is detectable.
local _quote = nil
package.loaded["lib/bookshelf_quotes"] = {
    forBook = function() return _quote end,
}
-- Deliberately NO repository stub: bookshelf_tokens.lua is barred from
-- requiring it, and this suite would mask that by satisfying the require.

local Tokens = dofile("lib/bookshelf_tokens.lua")
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

-- ── Every new catalogue entry is backed by an expander ─────────────────────

t.test("no new token renders as its own literal text", function()
    -- The failure this guards against is silent: the picker lists it, the
    -- reader inserts it, and the shelf shows the raw token back.
    local book = { filepath = "/b/Some Book.epub", page_count = 100 }
    for _i, tok in ipairs({ "%ssh_icon", "%quote_page", "%quote_chapter" }) do
        local out = Tokens.expand(tok, book, {})
        assert(out ~= tok, tok .. " has no expander behind it")
    end
end)

t.test("each new token is listed in the catalogue", function()
    -- A working expander nobody can discover is only half the feature.
    local listed = {}
    for _i, e in ipairs(Tokens.CATALOGUE) do listed[e.token] = true end
    for _i, tok in ipairs({ "%ssh_icon", "%quote_page", "%quote_chapter" }) do
        assert(listed[tok], tok .. " is missing from the picker")
    end
end)

-- ── SSH (issue 298) ────────────────────────────────────────────────────────

t.test("%ssh_icon is empty while the server is down", function()
    -- Empty, not an "off" glyph: a server that is not running is the normal
    -- state and does not earn permanent chrome. It also makes the token
    -- self-hiding without an [if:] wrapper.
    _ssh_present, _ssh_running = true, false
    eq(Tokens.expand("%ssh_icon", {}, {}), "")
end)

t.test("%ssh_icon shows a glyph while the server is up", function()
    _ssh_present, _ssh_running = true, true
    local out = Tokens.expand("%ssh_icon", {}, {})
    assert(out ~= "" and out ~= "%ssh_icon", "no glyph while SSH is running")
end)

t.test("[if:ssh] gates on the same state", function()
    _ssh_present, _ssh_running = true, true
    eq(Tokens.expand("[if:ssh]up[/if]", {}, {}), "up")
    _ssh_running = false
    eq(Tokens.expand("[if:ssh]up[/if]", {}, {}), "")
end)

t.test("a device without the SSH plugin reads as down, not as broken", function()
    -- No plugin means no server, which is the same answer -- and must not
    -- error on the many devices that never ship it.
    _ssh_present, _ssh_running = false, false
    eq(Tokens.expand("%ssh_icon", {}, {}), "")
    eq(Tokens.expand("[if:ssh]up[/if]", {}, {}), "")
end)

-- ── Quote page + chapter (issue 333) ───────────────────────────────────────

t.test("%quote_page and %quote_chapter report the picked highlight", function()
    _quote = { text = "a line", page_display = 42, chapter = "Chapter Three" }
    local book = { filepath = "/b/x.epub" }
    eq(Tokens.expand("%quote_page", book, {}), "42")
    eq(Tokens.expand("%quote_chapter", book, {}), "Chapter Three")
end)

t.test("all three quote tokens describe ONE highlight", function()
    -- The contract that matters: a template combining them must not attribute
    -- one quote to another's location.
    _quote = { text = "a line", page_display = 42, chapter = "Chapter Three" }
    local book = { filepath = "/b/x.epub" }
    local out = Tokens.expand("%quote / %quote_chapter / %quote_page", book, {})
    assert(out:find("a line", 1, true), "the quote text is missing")
    assert(out:find("Chapter Three", 1, true), "the chapter is missing")
    assert(out:find("42", 1, true), "the page is missing")
end)

t.test("a legacy highlight with no chapter yields empty, not nil text", function()
    -- Pre-annotations sidecars have no chapter field at all; [if:] gates it.
    _quote = { text = "a line", page_display = 7 }
    local book = { filepath = "/b/x.epub" }
    eq(Tokens.expand("%quote_chapter", book, {}), "")
    eq(Tokens.expand("%quote_page", book, {}), "7")
    eq(Tokens.expand("[if:quote_chapter]in %quote_chapter[/if]", book, {}), "")
end)

t.test("a book with no highlights renders both as empty", function()
    _quote = nil
    local book = { filepath = "/b/x.epub" }
    eq(Tokens.expand("%quote_page", book, {}), "")
    eq(Tokens.expand("%quote_chapter", book, {}), "")
end)

-- ── The icon has to stop showing when the server stops ─────────────────────

t.test("%ssh_icon has a refresh trigger", function()
    -- SOURCE-SHAPE. A token's value is baked into a TextWidget at REBUILD
    -- time, not paint time, so a value that changes on its own needs something
    -- to trigger a rebuild. Every other self-changing token has a group:
    -- TIMER_TOKENS for the minute tick, and WIFI / BATTERY / FRONTLIGHT /
    -- NIGHTMODE for their events.
    --
    -- %ssh_icon shipped in none of them. Rendered once, it outlived the server
    -- it was reporting -- the maintainer stopped SSH, the icon stayed, and it
    -- read as "I cannot stop the server". KOReader's SSH plugin broadcasts
    -- nothing to hang an event on, so the minute tick is what there is.
    local src = {}
    for line in io.lines("lib/bookshelf_widget.lua") do
        if not line:match("^%s*%-%-") then src[#src + 1] = line end
    end
    src = table.concat(src, "\n")
    local timer = src:match("local TIMER_TOKENS = {(.-)}")
    assert(timer, "TIMER_TOKENS is gone or was renamed")
    assert(timer:match('"ssh_icon"'),
        "%ssh_icon never refreshes, so it will outlive the server it reports")
    -- Both spellings: the match is "%name" plus a boundary, so "%ssh" does not
    -- fire for "%ssh_icon" and the [if:ssh] form needs its own entry.
    assert(timer:match('"ssh"'), "[if:ssh] has no refresh trigger")
end)

t.test("an xPointer never reaches the template", function()
    -- KOReader stores the highlight's LOCATION in `page`, and for a reflowable
    -- book that is an xPointer, not a number. %quote_page printed it verbatim
    -- and a reader got "/body/DocFragment[12]/body/div/p[3]/text()" on their
    -- shelf. Number-only is the guard; a book with no printable page renders
    -- empty, which [if:] gates.
    _quote = { text = "a line",
               page = "/body/DocFragment[12]/body/div/p[3]/text().0",
               page_display = nil }
    local book = { filepath = "/b/x.epub" }
    eq(Tokens.expand("%quote_page", book, {}), "",
        "the highlight's xPointer location reached the template")
end)

t.test("the printable page comes from the annotation, not the location", function()
    -- SOURCE-SHAPE on the producer, which is where the wrong field was read.
    -- pageref is the stable label and pageno the continuous number; preferring
    -- the label keeps %quote_page in the same scale as %page_count and
    -- %page_num, so a template mixing them does not compare two rulers.
    local qsrc = {}
    for line in io.lines("lib/bookshelf_quotes.lua") do
        if not line:match("^%s*%-%-") then qsrc[#qsrc + 1] = line end
    end
    qsrc = table.concat(qsrc, "\n")
    assert(qsrc:match("a%.pageref or a%.pageno"),
        "the quote's printable page no longer comes from pageref/pageno")
    assert(qsrc:match("page_display = tonumber%(page_display%)"),
        "page_display is no longer forced to a number")
end)

t.done()
