-- tests/_test_close_keeps_shelf.lua
-- Closing a book back to the shelf must LEAVE the shelf on the stack.
--
-- WHAT NEEDS PINNING. A real reader close runs, in this order, on the
-- reader-side plugin instance:
--
--   ReaderUI:onClose
--     handleEvent(CloseDocument)  -> Bookshelf:onCloseDocument   (schedules the re-show)
--     UIManager:close(self.dialog)-> Bookshelf:onCloseWidget     (closed the live shelf)
--
-- onCloseWidget closed the shelf the re-show was about to reuse, so the
-- scheduled show() found nothing live and cold-created a replacement: a full
-- _rebuild -- hero, a getAll hydrate of the visible page, every shelf row --
-- on the close path, where the warm branch would have run softRefresh
-- instead (a hero column swap, one spine repaint, and a shelf re-sort only
-- when the chip's sort actually depends on read state). Measured on the real
-- KOReader rig with 191 books: cold-create 128-148ms per close, of which
-- 40ms was a getAll hydrate that the warm path does not run at all. Issue
-- 422, where a 568-book library reported ~595ms in that hydrate alone.
--
-- The close is still load-bearing for the other cascades -- KOReader exiting
-- needs the stack to drain (issue 302), and a FileManager close must take
-- the shelf with it -- so the guard is keyed on the one-shot flag
-- onCloseDocument sets only on the path that WILL re-show.
--
-- Usage (from plugin root): lua tests/_test_close_keeps_shelf.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()

local src = io.open("main.lua"):read("*a")

local function body(name)
    local pat = "\nfunction " .. name:gsub("[%.%(%)%-]", "%%%0") .. "\n(.-)\nend\n"
    local b = src:match(pat)
    assert(b, "could not find " .. name .. " in main.lua - renamed?")
    return b
end

local function compile(code, env, chunk)  -- LuaJIT 5.1 and Lua 5.4 disagree here
    if _G.setfenv then
        local f = assert(_G.loadstring(code, chunk))
        _G.setfenv(f, env)
        return f
    end
    return assert(load(code, chunk, "t", env))
end

-- One env for both handlers: main.lua's file-locals (_live_widget, the
-- close-path flags) are upvalues there, so compiled standalone they resolve
-- as globals -- which is exactly what lets the flag one sets be seen by the
-- other, as it is in the real file.
local function newEnv(opts)
    opts = opts or {}
    local widget = { _opened_book = opts.opened_here ~= false, _refreshDitherFlag = function() end }
    local env = {
        _live_widget                  = widget,
        _restoring_from_reader        = false,
        _suppress_close_document_show = opts.suppress_show or false,
        _preserve_live_widget_on_reader_close = opts.preserve_shelf or false,
        _expect_onshow_takeover       = false,
        pairs = pairs, ipairs = ipairs, type = type, tostring = tostring,
        _ = function(s) return s end,
    }
    env.closed, env.ticks, env.timers = {}, {}, {}
    env.UIManager = {
        show          = function() end,
        close         = function(_self, w) env.closed[#env.closed + 1] = w end,
        setDirty      = function() end,
        isWidgetShown = function(_self, w) return w == widget and not opts.not_shown end,
        nextTick      = function(_self, fn) env.ticks[#env.ticks + 1] = fn end,
        scheduleIn    = function(_self, _s, fn) env.timers[#env.timers + 1] = fn end,
        unschedule    = function() end,
    }
    env.require = function(name)
        if name == "lib/bookshelf_book_repository" then
            return {
                invalidateStatsCache     = function() end,
                invalidateProgressCache  = function() end,
                invalidateReadStateCache = function() end,
            }
        end
        if name == "lib/bookshelf_reader_park" then
            return {
                noteRealClose      = function() end,
                consumeClosingToFM = function() return opts.closing_to_fm or false end,
                isFinishingClose   = function() return opts.finishing or false end,
                isExiting          = function() return opts.exiting or false end,
                ensureFileManager  = function() return false end,
            }
        end
        error("unexpected require: " .. tostring(name))
    end
    env.widget = widget
    return env
end

local function newSelf(opts)
    opts = opts or {}
    return {
        _isShowing    = function() return not opts.not_shown end,
        show          = function() end,
        _raiseInPlace = function() end,
        _cancelReaderPrewarm = function(self) self.prewarm_cancelled = true end,
        ui = {
            tearing_down = opts.switching or false,
            document     = { file = "/books/a.epub" },
        },
    }
end

local function runCloseDocument(env, self)
    compile("local self = ... ; " .. body("Bookshelf:onCloseDocument()"),
            env, "onCloseDocument")(self)
end

local function runCloseWidget(env, self)
    compile("local self = ... ; " .. body("Bookshelf:onCloseWidget()"),
            env, "onCloseWidget")(self)
end

t.test("a reader close heading back to the shelf leaves it on the stack", function()
    local env, self = newEnv(), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(self.prewarm_cancelled, true, "reader prewarming must stop before returning")
    H.eq(#env.closed, 0,
        "onCloseWidget closed the shelf the scheduled re-show was about to reuse")
end)

t.test("KOReader exiting still closes the shelf (issue 302)", function()
    local env, self = newEnv({ exiting = true }), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 1, "the exit path must still drain the window stack")
end)

t.test("a CloseWidget with no reader close behind it still closes the shelf", function()
    local env, self = newEnv(), newSelf()
    runCloseWidget(env, self)
    H.eq(#env.closed, 1, "an unrelated CloseWidget must still take the shelf with it")
end)

t.test("the keep is one-shot: a second CloseWidget closes", function()
    local env, self = newEnv(), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 1, "the flag must be consumed by the close it was set for")
end)

t.test("a close to the raw file browser still closes the shelf", function()
    local env, self = newEnv({ closing_to_fm = true }), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 1,
        "Park.closeShelfToFileManager's destination is the FileManager, not us")
end)

t.test("a reader-to-reader switch is untouched", function()
    -- tearing_down short-circuits onCloseWidget's own first guard, so the
    -- shelf survives a switch with or without the flag; pin that it stays so.
    local env, self = newEnv(), newSelf({ switching = true })
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 0, "the shelf must stay parked under the incoming reader")
end)

t.test("a SimpleUI-managed close preserves the shelf without another return", function()
    local env = newEnv({ preserve_shelf = true, suppress_show = true })
    local self = newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 0)
    H.eq(#env.ticks, 0, "SimpleUI's own return must not get a duplicate re-show")
    assert(not env._close_returns_to_shelf, "the normal return flag must stay unset")
end)

t.test("finishing a parked reader keeps the shelf without another return", function()
    local env, self = newEnv({ finishing = true }), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 0)
    H.eq(#env.ticks, 0, "the park finish already manages the shelf return")
    assert(not env._close_returns_to_shelf)
end)

t.test("a book opened by another home UI is not redirected to Bookshelf", function()
    local env, self = newEnv({ opened_here = false }), newSelf()
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.closed, 1)
    H.eq(#env.ticks, 0, "a parked shelf must not claim another UI's book")
end)

t.test("a warm return raises the surviving shelf above an existing file manager", function()
    local env, self = newEnv(), newSelf()
    local calls = {}
    self._raiseInPlace = function() calls[#calls + 1] = "raise" end
    self.show = function() calls[#calls + 1] = "show" end
    runCloseDocument(env, self)
    runCloseWidget(env, self)
    H.eq(#env.ticks, 1)
    env.ticks[1]()
    H.eq(calls, { "raise", "show" })
    H.eq(#env.closed, 0)
end)

t.test("the timed backstop releases a keep whose CloseWidget never arrived", function()
    local env, self = newEnv(), newSelf()
    runCloseDocument(env, self)
    for _, fn in ipairs(env.timers) do fn() end
    runCloseWidget(env, self)
    H.eq(#env.closed, 1, "a later unrelated close must not inherit the keep")
end)

t.done()
