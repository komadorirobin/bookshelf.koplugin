-- bookshelf_widget.lua
-- The top-level home screen widget. Composes TitleBar + HeroCard + ChipStrip
-- + shelf-pair label + two ShelfRows, owns chip-state and refresh.
--
-- Task 6.1: skeleton composition (titlebar stub, hero, chip strip, shelf pair)
-- Task 6.2: real TitleBar with gear icon; tappable shelf-pair label → LibraryView
-- Task 6.3: long-press book menu; series-stack expand-in-place
-- Task 9.1: empty states — chip-zero placeholder card

local InputContainer  = require("ui/widget/container/inputcontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget      = require("ui/widget/textwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local Size            = require("ui/size")
local Font            = require("ui/font")
local UIManager       = require("ui/uimanager")
local TitleBar        = require("ui/widget/titlebar")
local Blitbuffer      = require("ffi/blitbuffer")
local Screen          = require("device").screen

local _           = require("bookshelf_i18n").gettext

local Repo        = require("book_repository")
local HeroCard    = require("hero_card")
local ChipStrip   = require("chip_strip")
local ShelfRow    = require("shelf_row")
local LibraryView = require("library_view")

-- ─── BookshelfWidget ──────────────────────────────────────────────────────────

local BookshelfWidget = InputContainer:extend{
    name = "bookshelf",
    -- Internal state.
    chip             = "recent",
    _expanded_series = nil,
}

function BookshelfWidget:init()
    self.width  = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen  = Geom:new{ w = self.width, h = self.height }
    self.chip   = G_reader_settings:readSetting("bookshelf_active_chip") or "recent"
    self.page   = 1   -- 1-based; 8 books per page (4 cols × 2 shelves)

    -- Register top-zone touch zones so the standard KOReader menu opens via
    -- tap/swipe at the top of the screen, exactly as it does in FileManager.
    -- UIManager does not propagate non-consumed events to widgets below the
    -- top one, so we cannot rely on the underlying FileManager's own zones —
    -- we have to register our own and forward to FileManagerMenu directly.
    local DTAP_ZONE_MENU = G_defaults:readSetting("DTAP_ZONE_MENU")
    self:registerTouchZones({
        {
            id = "bookshelf_top_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
            },
            handler = function(ges) return self:_showStandardMenu(ges) end,
        },
        {
            id = "bookshelf_top_swipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = DTAP_ZONE_MENU.x, ratio_y = DTAP_ZONE_MENU.y,
                ratio_w = DTAP_ZONE_MENU.w, ratio_h = DTAP_ZONE_MENU.h,
            },
            handler = function(ges) return self:_showStandardMenu(ges) end,
        },
    })

    self:_rebuild()
end

-- Forward the standard top-zone gesture to FileManager's menu, mirroring
-- FileManagerMenu:onTapShowMenu / :onSwipeShowMenu behaviour so the menu
-- looks and behaves identically to the file manager's.
function BookshelfWidget:_showStandardMenu(ges)
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not fm or not fm.menu then return false end
    -- Swipe handler only fires on a south (downward) swipe; tap handler
    -- always fires for taps in the zone.
    if ges and ges.direction and ges.direction ~= "south" then
        return false
    end
    fm.menu:onShowMenu()
    return true
end

-- ─── _rebuild ─────────────────────────────────────────────────────────────────

function BookshelfWidget:_rebuild()
    -- Release previous widget tree before replacing (Phase 5 lesson).
    if self[1] and self[1].free then self[1]:free() end

    -- ── Single layout constant ────────────────────────────────────────────────
    -- ONE margin/padding value drives every gap on the home screen: page edges,
    -- cover-to-cover gap, hero text indent, and inter-section vertical gaps.
    -- Adjust this to tighten or loosen the entire layout proportionally.
    local PAD       = Size.padding.fullscreen * 2  -- ≈ 30dp at native scale
    local content_w = self.width - PAD * 2

    -- Height constants. Size.item.height_small does not exist (Phase 3-5 lesson);
    -- use height_default (~30dp) for all bar-height components.
    local chip_h  = Size.item.height_default
    local label_h = Size.item.height_default

    -- Hero card sized exactly to its cover (no internal padding budget). The
    -- VerticalSpan separators below the hero supply the gap to the chips, so
    -- adding internal padding here would double-count the space.
    local hero_cover_w = math.floor(content_w * 0.30)
    local hero_cover_h = math.floor(hero_cover_w * 1.5)
    local hero_h       = hero_cover_h

    -- Title bar removed: clock + battery moved to the bottom of the hero
    -- card right column (large font, below the progress bar). The gear
    -- menu is reachable via the system top-zone tap/swipe (FileManagerMenu)
    -- and via long-press on the hero or any cover.
    local titlebar_h = 0

    -- Each shelf row shares the remaining vertical space equally.
    local reserved_h = titlebar_h + hero_h + chip_h + label_h + PAD * 4
    local shelf_h    = math.floor((self.height - reserved_h) / 2)

    -- ── Hero card ─────────────────────────────────────────────────────────────
    local current = Repo.getCurrent()
    if current then Repo.enrichStats(current) end
    -- KOReader doesn't track EPUB page numbers outside an active reader
    -- session — `last_page` and `pages` are nil for cre documents on the
    -- home screen — so the page-X-of-Y formula reliably resolves to empty
    -- on the most common book format. The default line falls back to just
    -- the percentage. Users with PDF/CBZ libraries (where page counts ARE
    -- tracked) can still type "%page_num / %page_count · %book_pct" into
    -- Settings → Edit hero card lines.
    -- The progress bar already shows the percentage inline, so the default
    -- detail lines focus on book_time_left and (for PDF/CBZ books that
    -- expose page numbers) "Page X / Y".
    local lines = G_reader_settings:readSetting("bookshelf_hero_lines") or {
        "[if:page_num]Page %page_num / %page_count[/if]",
        "[if:book_time_left]%book_time_left LEFT[/if]",
    }
    local hero = HeroCard:new{
        book         = current,
        width        = content_w,
        height       = hero_h,
        cover_w      = hero_cover_w,
        cover_h      = hero_cover_h,
        pad          = PAD,                     -- single shared gap value
        lines        = lines,
        device_state = self:_buildDeviceState(),
        on_tap       = function(b) self:_openBook(b) end,
        on_hold      = function(b) self:_openBookMenu(b) end,
    }

    -- ── Chip strip ────────────────────────────────────────────────────────────
    local chips = ChipStrip:new{
        chips = {
            { key = "recent",    label = "Recent"  },
            { key = "latest",    label = "Latest"  },
            { key = "series",    label = "Series"  },
            { key = "favorites", label = "\xe2\x98\x85" },  -- ★ UTF-8
        },
        active   = self.chip,
        width    = content_w,
        height   = chip_h,
        on_change = function(key)
            -- Reset any expanded series, and reset to page 1, when switching chips.
            self._expanded_series = nil
            self.chip = key
            self.page = 1
            G_reader_settings:saveSetting("bookshelf_active_chip", key)
            self:_rebuild()
            UIManager:setDirty(self, "ui")
        end,
    }

    -- ── Shelf items ───────────────────────────────────────────────────────────
    -- Pagination: 8 per page (4 covers × 2 shelves). Fetch enough items to
    -- cover all pages, then slice the current window.
    local PAGE_SIZE  = 8
    local all_items  = self:_fetchChipItems(9999) or {}
    local total      = #all_items
    local total_pages = math.max(1, math.ceil(total / PAGE_SIZE))
    if self.page > total_pages then self.page = total_pages end
    if self.page < 1 then self.page = 1 end
    local start_idx  = (self.page - 1) * PAGE_SIZE + 1
    local items      = {}
    for i = 0, PAGE_SIZE - 1 do items[i + 1] = all_items[start_idx + i] end
    local shown      = #items
    -- Only count non-nil entries (the last page may be partial).
    local shown_count = 0
    for i = 1, PAGE_SIZE do if items[i] then shown_count = shown_count + 1 end end

    -- ── Empty-state placeholder (spec §8: "Selected chip yields zero books") ────
    -- When the active chip returns no items, replace both shelf rows with a
    -- single paper-card placeholder carrying chip-specific guidance text.
    -- This path is reached for:
    --   • "favorites"  when ReadCollection.favorites is empty or missing
    --   • "series"     when no books in ReadHistory carry series metadata
    --   • "recent"     when ReadHistory is empty
    --   • "latest"     when home_dir is empty / yields no supported files
    if #items == 0 then
        local placeholder_text
        if self.chip == "series" then
            placeholder_text = _("Nothing in Series yet · Add series metadata to your books and they will appear here")
        elseif self.chip == "favorites" then
            placeholder_text = _("No favourites yet · Long-press a book and tap 'Add to favourites'")
        elseif self.chip == "latest" then
            placeholder_text = _("No books found · Set your library folder in Settings then tap Latest")
        else
            placeholder_text = string.format(_("No books in %s yet"), self:_chipLabel())
        end

        -- Blitbuffer.gray semantics: 0 = white, 1 = black (i.e. "blackness level").
        -- Page background is plain white (matches e-ink unprinted paper);
        -- placeholder card has a faint grey tint to set it apart from the page.
        local paper_bg = Blitbuffer.COLOR_WHITE
        local card_bg  = Blitbuffer.gray(0.07)

        local placeholder = FrameContainer:new{
            bordersize = Size.border.thin,
            background = card_bg,
            padding    = Size.padding.large,
            width      = content_w,
            TextBoxWidget:new{
                text      = placeholder_text,
                face      = Font:getFace("infofont", 12),
                width     = content_w - Size.padding.large * 2,
                alignment = "center",
            },
        }

        self[1] = FrameContainer:new{
            bordersize = 0,
            padding    = PAD,
            background = paper_bg,
            -- Force the page background to fill the whole screen so the
            -- underlying FileManager doesn't bleed through below the content.
            width      = self.width,
            height     = self.height,
            VerticalGroup:new{
                align = "left",
                titlebar,
                hero,
                chips,
                placeholder,
            },
        }
        return
    end

    -- ── Footer-style pagination label ─────────────────────────────────────────
    -- Tappable: left half = previous page, right half = next page.
    -- When a series is expanded, the label reads "← Series name" and tapping
    -- anywhere collapses back to the chip's data.
    local is_expanded = (self._expanded_series ~= nil)
    local first_idx   = total > 0 and start_idx or 0
    local last_idx    = total > 0 and (start_idx + shown_count - 1) or 0
    local label_text
    if is_expanded then
        label_text = "\xe2\x86\x90  " .. (self._expanded_series.series_name or "Series")
    else
        local left_arrow  = self.page > 1           and "\xe2\x80\xb9  " or "   "
        local right_arrow = self.page < total_pages and "  \xe2\x80\xba" or ""
        label_text = string.format(
            "%s%s  \xc2\xb7  %d\xe2\x80\x93%d of %d%s",
            left_arrow, self:_chipLabel(), first_idx, last_idx, total, right_arrow
        )
    end

    local bw = self

    local ShelfLabel = InputContainer:extend{}
    function ShelfLabel:init()
        self.dimen = Geom:new{ w = content_w, h = label_h }
        self[1] = CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = label_h },
            TextWidget:new{
                text = label_text,
                face = Font:getFace("infofont", 11),
            },
        }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    function ShelfLabel:onTap(_, ges)
        if is_expanded then
            bw._expanded_series = nil
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
            return true
        end
        -- Resolve prev/next based on tap x relative to label centre.
        local x = ges and ges.pos and ges.pos.x or 0
        local centre = self.dimen.x + self.dimen.w / 2
        if x < centre and bw.page > 1 then
            bw.page = bw.page - 1
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        elseif x >= centre and bw.page < total_pages then
            bw.page = bw.page + 1
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end
        return true
    end
    local label_widget = ShelfLabel:new{}

    -- ── Shelf rows ────────────────────────────────────────────────────────────
    local items_top, items_bottom = {}, {}
    for i = 1, 4 do items_top[i]    = items[i]      end
    for i = 1, 4 do items_bottom[i] = items[i + 4]  end

    local row_top = ShelfRow.new{
        width          = content_w,
        height         = shelf_h,
        gap            = PAD,
        items          = items_top,
        on_book_tap    = function(b) bw:_openBook(b) end,
        on_book_hold   = function(b) bw:_openBookMenu(b) end,
        on_series_tap  = function(s) bw:_expandSeries(s) end,
        on_series_hold = function(s) bw:_openBookMenu(s) end,
    }
    local row_bottom = ShelfRow.new{
        width          = content_w,
        gap            = PAD,
        height         = shelf_h,
        items          = items_bottom,
        on_book_tap    = function(b) bw:_openBook(b) end,
        on_book_hold   = function(b) bw:_openBookMenu(b) end,
        on_series_tap  = function(s) bw:_expandSeries(s) end,
        on_series_hold = function(s) bw:_openBookMenu(s) end,
    }

    -- ── Assemble ──────────────────────────────────────────────────────────────
    -- Page background = pure white (e-ink unprinted paper). The defensive
    -- gray() guard from earlier was redundant AND used inverted semantics
    -- (0 = white, 1 = black per Blitbuffer.gray), which produced a near-black
    -- page on first render.
    local paper_bg = Blitbuffer.COLOR_WHITE

    -- Layout order: titlebar / hero / chips / shelf1 / shelf2 / footer-label.
    -- Pagination label moved BELOW the shelves so the shelves dominate the
    -- visual hierarchy and "1–8 of 10 ›" reads as a footer. VerticalSpan
    -- separators between sections give the home screen breathing room.
    local VerticalSpan = require("ui/widget/verticalspan")

    -- Inner content gets horizontal padding only; the titlebar above does
    -- not, so it spans the full screen width. Vertical PADs come from the
    -- VerticalSpan separators in the inner VerticalGroup.
    local inner_content = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_left  = PAD,
        padding_right = PAD,
        VerticalGroup:new{
            align = "left",
            hero,
            VerticalSpan:new{ width = PAD },
            chips,
            VerticalSpan:new{ width = PAD },
            row_top,
            VerticalSpan:new{ width = PAD },
            row_bottom,
            VerticalSpan:new{ width = PAD },
            label_widget,
        },
    }

    self[1] = FrameContainer:new{
        bordersize = 0,
        padding    = 0,           -- no outer padding — titlebar spans full width
        background = paper_bg,
        -- Force the page background to fill the whole screen so the
        -- underlying FileManager doesn't bleed through below the content.
        width      = self.width,
        height     = self.height,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = PAD },
            inner_content,
        },
    }
end

-- ─── Data helpers ─────────────────────────────────────────────────────────────

-- _fetchChipItems(n)
-- Returns up to n items for the current chip (or the expanded-series flat list).
function BookshelfWidget:_fetchChipItems(n)
    -- When a series is expanded, show that series' books as flat spine widgets.
    if self._expanded_series then
        return self._expanded_series.books
    end
    if self.chip == "recent"    then return Repo.getRecent(n)       end
    if self.chip == "latest"    then return Repo.getLatest(n)       end
    if self.chip == "series"    then return Repo.getSeriesGroups(n) end
    if self.chip == "favorites" then return Repo.getFavorites(n)    end
    return {}
end

-- _chipLabel()  — human-readable shelf heading for the active chip.
function BookshelfWidget:_chipLabel()
    if self._expanded_series then
        return (self._expanded_series.series_name or "Series")
    end
    local labels = {
        recent    = "Recently read",
        latest    = "Latest additions",
        series    = "Your series",
        favorites = "Favourites",
    }
    return labels[self.chip] or ""
end

-- _chipTotal() — total item count for the active chip (used in the label).
-- Returns -1 to signal "unknown" for chips where counting would be expensive
-- (e.g. "latest" requires a filesystem walk). The label-formatter omits the
-- total in that case.
function BookshelfWidget:_chipTotal()
    if self._expanded_series then
        return #self._expanded_series.books
    end
    -- For the active chip, count from the cheapest available source. The
    -- "latest" chip is filesystem-bound; counting it would re-walk every
    -- rebuild, so we return -1 to signal "unknown" and the label-formatter
    -- omits the total.
    if self.chip == "recent" then
        local rh = require("readhistory")
        local lastfile = G_reader_settings:readSetting("lastfile")
        local total = #rh.hist
        -- Mirror getRecent's dedup: lastfile is shown as the hero, so it doesn't
        -- count toward the Recent shelf total.
        if lastfile then
            for _i, entry in ipairs(rh.hist) do
                if entry.file == lastfile then total = total - 1; break end
            end
        end
        return total
    elseif self.chip == "latest" then
        return -1
    elseif self.chip == "series" then
        return #Repo.getSeriesGroups(9999)
    elseif self.chip == "favorites" then
        local rc = require("readcollection")
        local count = 0
        for _ in pairs(rc.coll and rc.coll.favorites or {}) do count = count + 1 end
        return count
    end
    return 0
end

-- ─── TitleBar (Task 6.2) ──────────────────────────────────────────────────────
-- Uses KOReader's TitleBar widget. A custom OverlapGroup approach is explicitly
-- avoided because TitleBar handles clock/battery/system-icon positioning
-- correctly (Phase 5 confirmed its API).

function BookshelfWidget:_buildTitleBar(w)
    -- Title carries the current time and, where available, battery%.
    -- "BOOKSHELF" label removed; clock+battery occupy the title slot directly.
    local ds = self:_buildDeviceState()
    local time_str = os.date("%H:%M")
    local batt_str = ""
    if ds.batt then
        batt_str = (ds.charging and "\xe2\x9a\xa1" or "") .. tostring(ds.batt) .. "%"
    end
    local title_text = batt_str ~= ""
        and string.format("%s   %s", time_str, batt_str)
        or  time_str
    return TitleBar:new{
        title                    = title_text,
        align                    = "left",
        width                    = w,
        fullscreen               = false,
        with_bottom_line         = true,
        right_icon               = "appbar.menu",
        right_icon_tap_callback  = function() self:_openGearMenu() end,
        show_parent              = self,
    }
end

-- ─── Device state ─────────────────────────────────────────────────────────────

function BookshelfWidget:_buildDeviceState()
    local ok_pd, PowerD = pcall(function()
        return require("device"):getPowerDevice()
    end)
    local ok_nm, NetMgr = pcall(require, "ui/network/manager")
    return {
        now      = os.time(),
        batt     = (ok_pd and PowerD and PowerD.getCapacity)
                       and PowerD:getCapacity() or nil,
        charging = (ok_pd and PowerD and PowerD.isCharging)
                       and PowerD:isCharging() or false,
        wifi     = (ok_nm and NetMgr and NetMgr.isWifiOn and NetMgr:isWifiOn())
                       and "on" or "off",
    }
end

-- ─── Navigation ───────────────────────────────────────────────────────────────

-- _openBook(book)  — close home screen, open ReaderUI for the given book.
-- ReaderUI is required inside the function to avoid boot-order issues (Phase 5 lesson).
function BookshelfWidget:_openBook(book)
    if not book or not book.filepath then return end
    -- Returning from a book should land on the chip-level view, not in the
    -- middle of an expanded series.
    self._expanded_series = nil
    local ReaderUI = require("apps/reader/readerui")
    UIManager:close(self)
    UIManager:nextTick(function()
        ReaderUI:showReader(book.filepath)
    end)
end

-- _browseFiles()  — close home screen, open FileManager.
function BookshelfWidget:_browseFiles()
    local FileManager = require("apps/filemanager/filemanager")
    local home = G_reader_settings:readSetting("home_dir") or "/"
    UIManager:close(self)
    UIManager:nextTick(function()
        FileManager:showFiles(home)
    end)
end

-- ─── Gear menu (Task 6.2) ─────────────────────────────────────────────────────

function BookshelfWidget:_openGearMenu()
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    UIManager:show(ButtonDialog:new{
        title = "Bookshelf",
        buttons = {
            {
                { text = G_reader_settings:readSetting("start_with") == "bookshelf"
                      and _("\xe2\x9c\x93 Bookshelf is my home screen")
                      or  _("Set as home screen"),
                  callback = function()
                    G_reader_settings:saveSetting("start_with", "bookshelf")
                    local ok_notif, Notification = pcall(require, "ui/widget/notification")
                    if ok_notif and Notification then
                        UIManager:show(Notification:new{
                            text = _("Bookshelf will load on next launch"),
                        })
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text    = _("Bookshelf will load on next launch"),
                            timeout = 2,
                        })
                    end
                  end },
            },
            {
                { text = "Browse files\xe2\x80\xa6",
                  callback = function() bw:_browseFiles() end },
            },
            {
                { text = "Settings\xe2\x80\xa6",
                  callback = function()
                    require("settings"):show()
                  end },
                { text = "About",
                  callback = function()
                    require("settings"):_about()
                  end },
            },
            {
                { text = "Cancel", callback = function() end },
            },
        },
    })
end

-- ─── Long-press book menu (Task 6.3) ─────────────────────────────────────────

-- _openBookMenu(item)
-- item may be a Book record (from a SpineWidget tap) or a SeriesGroup record
-- (from on_series_hold on a SeriesStack). Series groups have a .books field;
-- we route to a series-specific dialog in that case.
function BookshelfWidget:_openBookMenu(item)
    if not item then return end
    -- If the item is a series group, show a simpler series dialog.
    if item.books then
        return self:_openSeriesMenu(item)
    end
    local book = item
    local ButtonDialog   = require("ui/widget/buttondialog")
    local ReadCollection = require("readcollection")
    local bw = self
    local ok_fav, in_fav = pcall(function()
        return ReadCollection:isFileInCollection(book.filepath, "favorites")
    end)
    local fav_label = (ok_fav and in_fav)
        and "Remove from favourites" or "Add to favourites"
    UIManager:show(ButtonDialog:new{
        title = book.title or book.filename or "Book",
        buttons = {
            {
                { text = "Show info",
                  callback = function()
                    local FileManager = require("apps/filemanager/filemanager")
                    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
                    if FileManager.instance and FileManager.instance.bookinfo then
                        FileManager.instance.bookinfo:show(book.filepath)
                    else
                        FileManagerBookInfo:new{}:show(book.filepath)
                    end
                  end },
                { text = fav_label,
                  callback = function()
                    -- Toggle favourite status.
                    local ok, already = pcall(function()
                        return ReadCollection:isFileInCollection(book.filepath, "favorites")
                    end)
                    if ok and already then
                        ReadCollection:removeItem(book.filepath, "favorites")
                    else
                        ReadCollection:addItem(book.filepath, "favorites")
                    end
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end },
            },
            {
                { text = "Remove from history",
                  callback = function()
                    require("readhistory"):removeItemByPath(book.filepath)
                    bw:_rebuild()
                    UIManager:setDirty(bw, "ui")
                  end },
                { text = "Cancel", callback = function() end },
            },
        },
    })
end

-- _openSeriesMenu(series)  — long-press on a series stack.
function BookshelfWidget:_openSeriesMenu(series)
    local ButtonDialog = require("ui/widget/buttondialog")
    local bw = self
    UIManager:show(ButtonDialog:new{
        title = series.series_name or "Series",
        buttons = {
            {
                { text = "Browse series",
                  callback = function() bw:_expandSeries(series) end },
            },
            {
                { text = "Cancel", callback = function() end },
            },
        },
    })
end

-- ─── Series expand-in-place (Task 6.3) ───────────────────────────────────────

-- _expandSeries(series)  — replace the current shelf-pair with the series'
-- books as flat spine widgets. Tapping any chip resets this state.
function BookshelfWidget:_expandSeries(series)
    if not series then return end
    self._expanded_series = series
    self:_rebuild()
    UIManager:setDirty(self, "ui")
end

-- ─── Dismiss / passthrough ───────────────────────────────────────────────────

function BookshelfWidget:onClose()
    UIManager:close(self)
    return true
end

return BookshelfWidget
