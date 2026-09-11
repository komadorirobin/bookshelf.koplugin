-- tests/_test_desc_font_lazy_scroller.lua
-- The lazily-built description scroller renders at the CURRENT font size
-- (ReviewsModal:_makeScrollHtml) -- issue #363.
--
-- Usage (from plugin root): lua tests/_test_desc_font_lazy_scroller.lua
--
-- THE BUG. init captures _scroller_opts once, including default_font_size, at
-- whatever size the tab that opened first uses. Tapping the description opens
-- the popup ON the description, so the capture is the description's size and
-- everything is fine. Long-pressing opens it on EDIT and the reader switches
-- afterwards -- so the capture is the Edit tab's size, and _makeScrollHtml,
-- which refreshed only html_body, built the description's scroller at it.
--
-- Everything else was already correct and said so: the store held the right
-- number, _switchTab had loaded it into self.font_size, and the diagnostic
-- build logged the right key and value at every step. Only the pixels were
-- wrong. That is what made it worth a test rather than a one-line fix -- the
-- next person to read _makeScrollHtml sees a table being reused and no reason
-- to suspect one of its fields is stale.
--
-- Invisible whenever the two tabs' sizes match, which is why it survived: the
-- maintainer could not reproduce it, and the reporter (edit=18,
-- description=26) hit it every time.
--
-- bookshelf_reviews_modal.lua needs the whole KOReader widget stack to load, so
-- the method is extracted by name and run against a plain table. Its upvalues
-- (Screen, _gettime, logger) become globals in the extracted chunk and are
-- stubbed here -- the technique the widget-body suites use.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local makeScrollHtml
do
    local src = io.open("lib/bookshelf_reviews_modal.lua"):read("a")
    local body = src:match("\nfunction ReviewsModal:_makeScrollHtml%(%)\n(.-)\nend\n")
    assert(body, "ReviewsModal:_makeScrollHtml is gone or was renamed")
    local env = {
        -- scaleBySize doubles, so a size that was merely COPIED through is
        -- distinguishable from one that was never scaled at all.
        Screen   = { scaleBySize = function(_, n) return n * 2 end },
        _gettime = function() return 0 end,
        logger   = { dbg = function() end },
        string   = string,
    }
    local chunk = assert(load("local Screen, _gettime, logger = ...\n"
        .. "return function(self)\n" .. body .. "\nend"))
    makeScrollHtml = chunk(env.Screen, env._gettime, env.logger)
end

-- A modal shaped like the real one at the moment the description tab is first
-- shown: opts captured when the EDIT tab was active, font_size since updated
-- by _switchTab.
local function modal(captured_size, current_size)
    local built
    return {
        font_size       = current_size,
        _scroller_opts  = { default_font_size = captured_size, html_body = "<p>edit</p>" },
        _activeHtml     = function() return "<p>description</p>" end,
        _scroller       = function(_self, o) built = o; return { opts = o } end,
        seen            = function() return built end,
    }
end

t.test("the scroller is built at the size in force NOW", function()
    -- The reporter's numbers: opts captured at the Edit tab's 18, description
    -- switched to and holding 26. scaleBySize doubles, so 52 is the answer and
    -- 36 is the bug.
    local m = modal(36, 26)
    makeScrollHtml(m)
    eq(m.seen().default_font_size, 52,
        "the description rendered at the tab that opened first, not its own size")
end)

t.test("the content is still refreshed too", function()
    -- The pre-existing half of the refresh, which must not be lost.
    local m = modal(36, 26)
    makeScrollHtml(m)
    eq(m.seen().html_body, "<p>description</p>")
end)

t.test("matching sizes are unaffected", function()
    -- Why this went unreported for so long and could not be reproduced: when
    -- both tabs sit at the same size the stale capture IS the right number.
    local m = modal(52, 26)
    makeScrollHtml(m)
    eq(m.seen().default_font_size, 52)
end)

t.test("no opts table means no scroller, not a crash", function()
    local m = modal(36, 26)
    m._scroller_opts = nil
    eq(makeScrollHtml(m), nil)
end)

t.done()
