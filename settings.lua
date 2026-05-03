-- settings.lua
-- Gear-menu settings modal for Bookshelf: hero-card line editor, font scale,
-- progress-bar toggle, latest-walk depth, titlebar-meta toggle, About.
--
-- Public API: Settings:show()
-- All persisted keys use the bookshelf_* prefix.

local InfoMessage  = require("ui/widget/infomessage")
local InputDialog  = require("ui/widget/inputdialog")
local Menu         = require("ui/widget/menu")
local SpinWidget   = require("ui/widget/spinwidget")
local UIManager    = require("ui/uimanager")
local _            = require("bookshelf_i18n").gettext

-- ─── Settings singleton ───────────────────────────────────────────────────────

local Settings = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function readLines()
    return G_reader_settings:readSetting("bookshelf_hero_lines") or {
        "[if:page_num]Page %page_num / %page_count[/if]",
        "[if:book_time_left]%book_time_left LEFT[/if]",
    }
end

local function writeLines(lines)
    G_reader_settings:saveSetting("bookshelf_hero_lines", lines)
end

-- ─── Toggle helpers ───────────────────────────────────────────────────────────

local function isTrue(key)
    return G_reader_settings:isTrue(key)
end

local function checkmark(key)
    -- Return nil (not "") for the off state so Menu omits the mandatory
    -- TextWidget rather than allocating an empty one (which would take
    -- space and misalign rows).
    if isTrue(key) then return "\xe2\x9c\x93" end
    return nil
end

-- ─── Sub-actions ──────────────────────────────────────────────────────────────

-- _editLine(idx, lines, menu_ref)
-- Opens an InputDialog for line `idx`.  When saved, persists lines and chains
-- to the next line editor if idx < 2.  Stores the dialog in a local so the
-- Cancel/Save callbacks can close it without touching Settings state.
function Settings:_editLine(idx, lines, menu_ref)
    local dialog  -- forward declaration so callbacks can close it

    dialog = InputDialog:new{
        title   = string.format(_("Hero card line %d"), idx),
        input   = lines[idx] or "",
        buttons = {
            {
                {
                    text     = _("Cancel"),
                    id       = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text             = _("Save"),
                    is_enter_default = true,
                    callback         = function()
                        local text = dialog:getInputText()
                        lines[idx] = text or ""
                        writeLines(lines)
                        UIManager:close(dialog)
                        if idx < 2 then
                            -- Chain to the next line editor.
                            self:_editLine(idx + 1, lines, menu_ref)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Settings:_editLines(menu_ref)
    local lines = readLines()
    self:_editLine(1, lines, menu_ref)
end

function Settings:_pickFontScale()
    local current = G_reader_settings:readSetting("bookshelf_font_scale") or 100
    UIManager:show(SpinWidget:new{
        value      = current,
        value_min  = 75,
        value_max  = 150,
        value_step = 25,
        unit       = "%",
        title_text = _("Hero card font scale"),
        callback   = function(spin)
            G_reader_settings:saveSetting("bookshelf_font_scale", spin.value)
        end,
    })
end

function Settings:_pickLatestDepth()
    local current = G_reader_settings:readSetting("bookshelf_latest_walk_depth") or 3
    UIManager:show(SpinWidget:new{
        value      = current,
        value_min  = 1,
        value_max  = 99,
        value_step = 1,
        title_text = _("\"Latest\" folder walk depth"),
        info_text  = _("How deep to scan your library folder for newly-added books."
                        .. " Higher values take longer on a cold start."),
        callback   = function(spin)
            G_reader_settings:saveSetting("bookshelf_latest_walk_depth", spin.value)
        end,
    })
end

function Settings:_about()
    local ok, meta = pcall(require, "_meta")
    local name    = ok and meta.fullname    or "Bookshelf"
    local version = ok and meta.version     or "0.1.0"
    local desc    = ok and meta.description or ""
    UIManager:show(InfoMessage:new{
        text = string.format("%s  v%s\n\n%s", name, version, desc),
    })
end

-- ─── Main settings menu ───────────────────────────────────────────────────────

-- Settings:show()
-- Opens the settings menu as a popout modal.  Toggle items show "✓" on the
-- right when enabled (via mandatory_func).  After toggling, the menu is
-- re-opened so the user can see the updated state.
function Settings:show()
    -- Singleton guard: don't stack settings menus.
    if self._menu then return end

    local item_table = {
        {
            text = _("Edit hero card lines"),
            callback = function() self:_closeAnd(function() self:_editLines() end) end,
        },
        {
            text = _("Hero card font scale"),
            callback = function() self:_closeAnd(function() self:_pickFontScale() end) end,
        },
        {
            text           = _("Show book progress bar"),
            mandatory_func = function() return checkmark("bookshelf_show_progress") end,
            callback = function()
                local v = not isTrue("bookshelf_show_progress")
                G_reader_settings:saveSetting("bookshelf_show_progress", v)
                self:_reopen()
            end,
        },
        {
            text = _("\"Latest\" walk depth"),
            callback = function() self:_closeAnd(function() self:_pickLatestDepth() end) end,
        },
        {
            text           = _("Show clock and battery in titlebar"),
            mandatory_func = function() return checkmark("bookshelf_show_titlebar_meta") end,
            callback = function()
                local v = not isTrue("bookshelf_show_titlebar_meta")
                G_reader_settings:saveSetting("bookshelf_show_titlebar_meta", v)
                self:_reopen()
            end,
        },
        {
            text = _("About"),
            callback = function() self:_closeAnd(function() self:_about() end) end,
        },
    }

    self._menu = Menu:new{
        title          = _("Bookshelf settings"),
        item_table     = item_table,
        is_popout      = true,
        close_callback = function()
            -- Allow GC by clearing the reference. UIManager owns the actual close.
            self._menu = nil
        end,
    }
    UIManager:show(self._menu)
end

function Settings:_closeAnd(action)
    -- Used for items that open another widget (InputDialog/SpinWidget/InfoMessage):
    -- close the menu first, then dispatch the next widget on the next tick.
    if self._menu then UIManager:close(self._menu); self._menu = nil end
    UIManager:nextTick(action)
end

function Settings:_reopen()
    -- Used for toggle items: close-and-reopen so the user sees the updated state.
    if self._menu then UIManager:close(self._menu); self._menu = nil end
    UIManager:nextTick(function() self:show() end)
end

return Settings
