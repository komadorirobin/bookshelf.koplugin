-- bookshelf_i18n.lua
-- Thin wrapper around KOReader's gettext so we can lazy-load and avoid
-- requiring gettext at module-load time in pure-Lua tests.

local M = {}

local _gettext
function M.gettext(s)
    if not _gettext then
        local ok, gettext = pcall(require, "gettext")
        _gettext = ok and gettext or function(t) return t end
    end
    return _gettext(s)
end

function M.ngettext(s, p, n)
    if not _gettext then
        local ok, gettext = pcall(require, "gettext")
        _gettext = ok and gettext.ngettext or function(t, _, _) return t end
    end
    return _gettext.ngettext(s, p, n)
end

return M
