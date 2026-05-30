-- bookshelf_hero_regions.lua
-- Single source of truth for the hero card's five editable regions:
-- defaults, sparse-field resolution, persistence helpers, and the
-- canonical render order. Pure Lua, KOReader-free at load time.

local Regions = {}

Regions.SETTINGS_KEY = "bookshelf_hero_regions"

-- Render order from top to bottom. Renderer and chooser modal both use
-- this list. Adding a region means adding it here AND adding a default.
Regions.ORDER = { "status", "rating", "title", "author", "metadata", "description", "tags", "progress" }

Regions.DEFAULTS = {
    status = {
        template  = "\xef\x82\xa0 %disk[if:batt]  %batt_icon%batt[/if]"
                 .. "[if:light]  %light_icon%light_pct[/if]  %wifi_icon  %time_12h",
        font_face = nil,
        font_size = 14,
        bold      = false,
        uppercase = false,
        alignment = "right",
    },
    title = {
        template  = "%title",
        font_face = nil,
        font_size = 26,
        bold      = true,
        uppercase = false,
        alignment = "left",
        -- Tight leading: titles are the dominant visual element, and
        -- TextBoxWidget's 0.3em default puts so much space between
        -- wrapped title lines that it exceeds the title→author gap —
        -- the reverse of what reads well. 0.05em gives the lines a
        -- small but discernible breather without breaking the
        -- title-as-unit feel.
        line_height = 0.05,
    },
    -- Metadata: an extra line between author and description. EPUB has no
    -- formal subtitle/metadata field, but the dominant use case is showing
    -- series info via a conditional template — the user can substitute
    -- their own static text or template for any other purpose. Empty
    -- template = region collapses (Tokens.isEmpty check skips paint).
    metadata = {
        template  = "[if:series]%series_name[if:series_num] / #%series_num[/if][/if]",
        font_face = nil,
        font_size = 14,
        bold      = true,
        uppercase = false,
        alignment = "right",
    },
    author = {
        template  = "[if:authors]%authors[else]%author[/if]",
        font_face = nil,
        font_size = 16,
        bold      = false,
        uppercase = false,
        alignment = "left",
    },
    -- Interactive 5-star rating row. Stores the rating in DocSettings
    -- summary.rating like KOReader's Book Status dialog. Tap a star to
    -- set; tap the current star again to clear. No template -- the
    -- entry just carries the on/off + visual settings.
    rating = {
        template  = "",       -- ignored; rating is widgets, not text
        font_size = 20,       -- maps directly to star glyph size
        alignment = "left",
        disabled  = true,     -- off by default; user opts in
    },
    description = {
        template  = "%description",
        font_face = nil,
        font_size = 14,
        bold      = false,
        alignment = "left",
        -- no `uppercase` — would be hostile on a long blurb
    },
    progress = {
        template   = "[if:page_num]%page_num / %page_count[else]%book_pct[/if]  %bar  [if:book_time_left]%book_time_left LEFT[/if]",
        font_face  = nil,
        font_size  = 14,
        bold       = true,
        uppercase  = false,
        alignment  = "left",
        bar_height = nil,         -- percentage of rendered text height; nil = 100% (match)
        bar_style  = "bordered",
    },
    -- Interactive pill strip: same author / series / collection / genre /
    -- folder pills the long-press book menu renders, but inline on the
    -- hero. Tappable -- each pill drills into the matching view. Off by
    -- default (opt-in); when enabled sits above the progress bar and
    -- eats into the description's vertical slack.
    tags = {
        template = "",     -- ignored; pills are widgets, not text
        disabled = true,   -- off by default
    },
}

-- Labels for the chooser modal. English-only here; settings.lua wraps in _().
Regions.LABELS = {
    status      = "Status line",
    title       = "Title",
    author      = "Author",
    rating      = "Rating (interactive)",
    metadata    = "Metadata",
    description = "Description",
    tags        = "Tags (interactive)",
    progress    = "Progress",
}

local function isRegionKey(key)
    for _i, k in ipairs(Regions.ORDER) do
        if k == key then return true end
    end
    return false
end

local function shallowCopy(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

local function resolveOne(key, raw)
    local default = Regions.DEFAULTS[key]
    local out = shallowCopy(default) or {}
    if type(raw) == "table" then
        for k, v in pairs(raw) do
            local vt = type(v)
            if vt == "string" or vt == "number" or vt == "boolean" then
                out[k] = v
            end
        end
        -- Reject malformed template (must be a string).
        if type(raw.template) ~= "string" then
            out.template = default.template
        end
    end
    return out
end

-- Read raw stored table (no resolution). Helper for snapshot/restore.
local function readRaw()
    return G_reader_settings:readSetting(Regions.SETTINGS_KEY) or {}
end

-- read() — returns a fully-resolved table keyed by region name. Always
-- has every region populated; sparse stored fields fall through to defaults.
--
-- Memoised behind a private cache invalidated by write() / restore().
-- HeroCard:_buildRightColumn calls this once per hero rebuild and the
-- result feeds six Tokens.expand calls — the resolved table doesn't
-- change between calls unless the user opens the line editor and saves
-- a region. Returns the SHARED cached table; callers must not mutate.
local _read_cache
local _read_cache_raw
function Regions.read()
    local raw = readRaw()
    if _read_cache and raw == _read_cache_raw then
        return _read_cache
    end
    local out = {}
    for _i, key in ipairs(Regions.ORDER) do
        out[key] = resolveOne(key, raw[key])
    end
    _read_cache = out
    _read_cache_raw = raw
    return out
end

-- Drop the cache. Called from write() so the next read() reflects the
-- new state; exposed for tests / one-off cache invalidation.
function Regions.invalidateCache()
    _read_cache = nil
    _read_cache_raw = nil
end

-- resolve(key, raw_entry) — exposed for tests / one-off use; same logic
-- as the per-region pass inside read().
function Regions.resolve(key, raw)
    if not isRegionKey(key) then return nil end
    return resolveOne(key, raw)
end

-- write(key, entry) — persist one region. Pass entry=nil to clear back
-- to defaults (the entry is removed from storage entirely).
function Regions.write(key, entry)
    if not isRegionKey(key) then return end
    local stored = readRaw()
    stored[key] = entry
    G_reader_settings:saveSetting(Regions.SETTINGS_KEY, stored)
    G_reader_settings:flush()
    Regions.invalidateCache()
end

-- snapshot(key) — deep-copy the *raw* stored entry for a region (or nil
-- if there is none). Cheap because the schema is one level deep.
function Regions.snapshot(key)
    if not isRegionKey(key) then return nil end
    local raw = readRaw()
    return shallowCopy(raw[key])
end

-- restore(key, snap) — opposite of snapshot. Pass the table returned by
-- snapshot; nil clears the entry. Used by the line editor's Cancel path.
function Regions.restore(key, snap)
    Regions.write(key, snap)
end

return Regions
