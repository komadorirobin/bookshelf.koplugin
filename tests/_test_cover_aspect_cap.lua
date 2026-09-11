-- tests/_test_cover_aspect_cap.lua
-- The tallest-cover cap is settable (SpineWidget.coverAspectCap) -- issue #330.
--
-- Usage (from plugin root): lua tests/_test_cover_aspect_cap.lua
--
-- WHY A TEST. The cap is not a display preference: the row-count maths reserves
-- height at this number and shelf_row sizes its slots with it, so EVERY reader
-- has to agree on one value. A previous retune moved the constant while a
-- hardcoded 1.65 stayed behind in the row maths, and the result was covers that
-- shrank without giving back the row the tightening was for. Turning the
-- constant into a setting multiplies the ways that can happen again, so what is
-- pinned here is that the accessor is the single source and that a bad stored
-- value cannot escape the usable range.

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local stored, generation = nil, 1
package.loaded["lib/bookshelf_settings_store"] = {
    read = function(k, d) if k == "cover_aspect_cap" then return stored end return d end,
    isTrue = function() return false end,
    generation = function() return generation end,
}
local function setCap(v) stored = v; generation = generation + 1 end

-- Only the pure accessor is exercised; the module's render deps are stubbed by
-- the same shape the other spine suites use.
local function make_widget_base()
    local W = {}
    W.__index = W
    function W:extend(o) o = o or {}; setmetatable(o, self); self.__index = self; return o end
    function W:new(o) o = o or {}; setmetatable(o, self); self.__index = self; if self.init then self:init() end; return o end
    function W:init() end
    return W
end
for _, n in ipairs({ "ui/widget/widget", "ui/widget/overlapgroup",
    "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
    "ui/widget/container/bottomcontainer", "ui/widget/container/rightcontainer",
    "ui/widget/container/inputcontainer", "ui/widget/imagewidget" }) do
    package.preload[n] = function() return make_widget_base() end
end
package.preload["ui/geometry"] = function()
    return { new = function(_, t) return setmetatable(t or {}, { __index = {} }) end }
end
package.preload["ui/gesturerange"] = function() return { new = function(_, t) return t end } end
package.preload["ui/size"] = function()
    return { padding = { small = 3, default = 5, large = 10, fullscreen = 15 },
             border = { thin = 1, medium = 2 } }
end
package.preload["ui/bidi"] = function() return { mirroredUILayout = function() return false end } end
package.preload["ffi/blitbuffer"] = function()
    return { Color8 = function(n) return { v = n } end,
             ColorRGB32 = function(r,g,b,a) return { r=r,g=g,b=b,a=a } end,
             COLOR_WHITE = {}, COLOR_BLACK = {},
             gray = function(n) return { gray = n } end, new = function() return {} end }
end
package.preload["ffi"] = function()
    return { typeof = function() return {} end, istype = function() return false end,
             metatype = function() end, cdef = function() end, new = function() return {} end }
end
package.preload["ffi/util"] = function() return { template = function(s) return s end } end
package.preload["device"] = function()
    return { isAndroid = function() return false end,
             screen = { isColorEnabled = function() return false end,
                        scaleBySize = function(_, n) return n end } }
end
package.preload["lib/bookshelf_scaled_cover_cache"] = function()
    return { get = function() return nil end, put = function(_, _, bb) return bb end }
end
package.preload["lib/bookshelf_fonts"] = function() return { getFace = function() return {}, {} end } end
package.preload["lib/bookshelf_cover_progress"] = function()
    return { badgeSize = function(n) return n end, glyphRenderedH = function() return 0 end,
             resolvedColors = function() return {} end, decide = function() return {} end,
             paintRoundedRect = function() end }
end
package.preload["lib/bookshelf_i18n"] = function() return { gettext = function(s) return s end } end
_G.G_reader_settings = { isTrue = function() return false end, nilOrTrue = function() return true end }

local SpineWidget = require("lib/bookshelf_spine_widget")

t.test("unset falls back to the documented default", function()
    setCap(nil)
    eq(SpineWidget.coverAspectCap(), SpineWidget.COVER_ASPECT_CAP)
    eq(SpineWidget.COVER_ASPECT_CAP, 1.55, "the default moved without the "
        .. "measurement in its comment being revisited")
end)

t.test("a stored value is honoured", function()
    setCap(1.8)
    eq(SpineWidget.coverAspectCap(), 1.8)
    setCap(1.4)
    eq(SpineWidget.coverAspectCap(), 1.4)
end)

t.test("a value outside the usable range falls back", function()
    -- Below ~1.2 covers stop reading as books; above ~2.0 one row eats the
    -- screen. A stored value can only arrive from this plugin's own menu, but
    -- settings files are hand-edited and survive downgrades.
    for _i, bad in ipairs({ 0, 0.5, 1.19, 2.01, 99 }) do
        setCap(bad)
        eq(SpineWidget.coverAspectCap(), SpineWidget.COVER_ASPECT_CAP,
            "a cap of " .. bad .. " escaped the clamp")
    end
end)

t.test("a non-number falls back rather than erroring", function()
    setCap("tall")
    eq(SpineWidget.coverAspectCap(), SpineWidget.COVER_ASPECT_CAP)
end)

t.test("bookAspect trims to the cap in force, not the constant", function()
    -- The whole point: a 2.0-shaped cover must follow the reader's setting.
    setCap(1.8)
    eq(SpineWidget.bookAspect({ cover_sizetag = "100x200" }), 1.8)
    setCap(1.4)
    eq(SpineWidget.bookAspect({ cover_sizetag = "100x200" }), 1.4)
end)

t.test("a cover under the cap is untouched by it", function()
    setCap(1.8)
    eq(SpineWidget.bookAspect({ cover_sizetag = "100x150" }), 1.5)
end)

t.test("the value is re-read when settings change", function()
    -- Memoised per settings generation, because bookAspect runs per cover per
    -- render; a memo that never invalidated would need a restart to take.
    setCap(1.4)
    eq(SpineWidget.coverAspectCap(), 1.4)
    setCap(1.65)
    eq(SpineWidget.coverAspectCap(), 1.65, "the memo outlived the setting")
end)

t.done()
