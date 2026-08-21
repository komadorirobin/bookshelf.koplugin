-- bookshelf_epub_metadata.lua
-- Small, cached EPUB OPF helpers for metadata that KOReader's
-- BookInfoManager currently flattens away (notably creator roles,
-- illustrators, and EPUB 3 title refinements such as subtitles).

local EpubMetadata = {}

local function _shellQuote(s)
    return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function _xmlDecode(s)
    if not s then return "" end
    return (s:gsub("&lt;", "<")
             :gsub("&gt;", ">")
             :gsub("&quot;", "\"")
             :gsub("&apos;", "'")
             :gsub("&amp;", "&"))
end

local function _trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function _cleanText(s)
    s = _xmlDecode(tostring(s or ""):gsub("<[^>]+>", ""))
    s = s:gsub("%s+", " ")
    return _trim(s)
end

local function _attr(attrs, name)
    if type(attrs) ~= "string" then return nil end
    local pattern_dq = name .. '%s*=%s*"([^"]+)"'
    local pattern_sq = name .. "%s*=%s*'([^']+)'"
    return attrs:match(pattern_dq) or attrs:match(pattern_sq)
end

local function _normaliseRole(role)
    role = _trim(_xmlDecode(role or "")):lower()
    role = role:gsub("^marc:relators:", "")
               :gsub("^marc:relators#", "")
               :gsub("^http://id%.loc%.gov/vocabulary/relators/", "")
    return role
end

local function _isAuthorRole(role)
    role = _normaliseRole(role)
    return role == "aut" or role == "author"
end

local function _copyList(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

function EpubMetadata.extractAuthorCreatorsFromOpf(opf)
    if type(opf) ~= "string" or opf == "" then return nil end

    -- EPUB 3 commonly stores roles as:
    --   <dc:creator id="creator01">Name</dc:creator>
    --   <meta refines="#creator01" property="role">aut</meta>
    local refined_roles = {}
    -- Require whitespace after the tag name so the outer <metadata> element
    -- cannot be mistaken for a <meta> element.
    for attrs, value in opf:gmatch(
            "<%s*[%w_%-:]-meta%s+([^>]*)>(.-)</%s*[%w_%-:]-meta%s*>") do
        local property = (_attr(attrs, "property") or ""):lower()
        local refines = _attr(attrs, "refines")
        if property == "role" and refines then
            local id = refines:gsub("^#", "")
            refined_roles[id] = _normaliseRole(value)
        end
    end

    local authors, seen = {}, {}
    local function add(name)
        name = _cleanText(name)
        if name ~= "" and not seen[name] then
            seen[name] = true
            authors[#authors + 1] = name
        end
    end

    for attrs, value in opf:gmatch("<%s*[%w_%-:]*creator([^>]*)>(.-)</%s*[%w_%-:]*creator%s*>") do
        local role = _attr(attrs, "opf:role") or _attr(attrs, "role")
        local id = _attr(attrs, "id")
        if (not role or role == "") and id then
            role = refined_roles[id]
        end
        if _isAuthorRole(role) then
            add(value)
        end
    end

    return #authors > 0 and authors or nil
end

-- EPUB 3 represents a subtitle as another dc:title whose id is refined by a
-- title-type meta entry. BookOrbit writes this standards-based form:
--
--   <dc:title id="t-sub">The Strength of the Hashira</dc:title>
--   <meta refines="#t-sub" property="title-type">subtitle</meta>
--
-- KOReader's BookInfoManager currently keeps only the main title, so retain
-- the refinement here. The BookOrbit custom meta fallback supports files
-- written by older/intermediate versions without guessing that an arbitrary
-- second, untyped dc:title is a subtitle.
function EpubMetadata.extractSubtitleFromOpf(opf)
    if type(opf) ~= "string" or opf == "" then return nil end

    local subtitle_ids = {}
    local property_subtitle
    for attrs, value in opf:gmatch(
            "<%s*[%w_%-:]-meta%s+([^>]*)>(.-)</%s*[%w_%-:]-meta%s*>") do
        local property = (_attr(attrs, "property") or ""):lower()
        local refines = _attr(attrs, "refines")
        local cleaned = _cleanText(value)
        if property == "title-type" and refines and cleaned:lower() == "subtitle" then
            subtitle_ids[refines:gsub("^#", "")] = true
        elseif property == "bookorbit:subtitle" and cleaned ~= "" then
            property_subtitle = cleaned
        end
    end

    for attrs, value in opf:gmatch("<%s*[%w_%-:]*title([^>]*)>(.-)</%s*[%w_%-:]*title%s*>") do
        local id = _attr(attrs, "id")
        if id and subtitle_ids[id] then
            local subtitle = _cleanText(value)
            if subtitle ~= "" then return subtitle end
        end
    end

    if property_subtitle then return property_subtitle end

    for attrs in opf:gmatch("<%s*[%w_%-:]-meta%s+([^>]*)/?>") do
        local name = (_attr(attrs, "name") or ""):lower()
        if name == "bookorbit:subtitle" then
            local subtitle = _cleanText(_attr(attrs, "content"))
            if subtitle ~= "" then return subtitle end
        end
    end
    return nil
end

-- BookOrbit writes custom contributor metadata as property meta elements.
-- Prefer those explicit fields, then fall back to standard EPUB contributor
-- roles so files produced by other metadata editors work too.
local function _extractContributorFromOpf(opf, custom_property, accepted_roles)
    if type(opf) ~= "string" or opf == "" then return nil end

    local refined_roles = {}
    for attrs, value in opf:gmatch(
            "<%s*[%w_%-:]-meta%s+([^>]*)>(.-)</%s*[%w_%-:]-meta%s*>") do
        local property = (_attr(attrs, "property") or ""):lower()
        local cleaned = _cleanText(value)
        if property == custom_property and cleaned ~= "" then
            return cleaned
        end
        local refines = _attr(attrs, "refines")
        if property == "role" and refines then
            refined_roles[refines:gsub("^#", "")] = _normaliseRole(value)
        end
    end

    -- Also accept the legacy name/content spelling if BookOrbit or another
    -- editor serialises custom fields as an EPUB 2-style self-closing meta.
    for attrs in opf:gmatch("<%s*[%w_%-:]-meta%s+([^>]*)/?>") do
        local name = (_attr(attrs, "name") or ""):lower()
        if name == custom_property then
            local contributor = _cleanText(_attr(attrs, "content"))
            if contributor ~= "" then return contributor end
        end
    end

    local function fromElements(element)
        local pattern = "<%s*[%w_%-:]*" .. element
            .. "([^>]*)>(.-)</%s*[%w_%-:]*" .. element .. "%s*>"
        for attrs, value in opf:gmatch(pattern) do
            local role = _attr(attrs, "opf:role") or _attr(attrs, "role")
            local id = _attr(attrs, "id")
            if (not role or role == "") and id then role = refined_roles[id] end
            role = _normaliseRole(role)
            if accepted_roles[role] then
                local contributor = _cleanText(value)
                if contributor ~= "" then return contributor end
            end
        end
    end

    return fromElements("contributor") or fromElements("creator")
end

function EpubMetadata.extractIllustratorFromOpf(opf)
    return _extractContributorFromOpf(opf, "bookorbit:custom:illustrator", {
        ill = true, illustrator = true,
    })
end

function EpubMetadata.extractTranslatorFromOpf(opf)
    return _extractContributorFromOpf(opf, "bookorbit:custom:translator", {
        trl = true, translator = true,
    })
end

local function _readCommand(cmd, max_bytes)
    local ok, fh = pcall(io.popen, cmd, "r")
    if not ok or not fh then return nil end
    local chunks, total = {}, 0
    for line in fh:lines() do
        total = total + #line
        if max_bytes and total > max_bytes then break end
        chunks[#chunks + 1] = line
    end
    fh:close()
    return #chunks > 0 and table.concat(chunks, "\n") or nil
end

local function _readOpfPath(filepath)
    local container = _readCommand(
        "unzip -p " .. _shellQuote(filepath) .. " META-INF/container.xml 2>/dev/null",
        128 * 1024)
    if container then
        local path = container:match("<%s*rootfile[^>]-full%-path%s*=%s*\"([^\"]+)\"")
                  or container:match("<%s*rootfile[^>]-full%-path%s*=%s*'([^']+)'")
        if path and path ~= "" then return _xmlDecode(path) end
    end

    local listing = _readCommand(
        "unzip -lqq " .. _shellQuote(filepath) .. " '*.opf' 2>/dev/null",
        256 * 1024)
    if not listing then return nil end
    for line in listing:gmatch("[^\n]+") do
        local path = line:match("%s+%d+%s+%S+%s+%S+%s+(.+%.opf)$")
                  or line:match("([^%s].-%.opf)$")
        if path then return path end
    end
    return nil
end

local function _readOpfFromEpub(filepath)
    local opf_path = _readOpfPath(filepath)
    if not opf_path then return nil end
    return _readCommand(
        "unzip -p " .. _shellQuote(filepath) .. " " .. _shellQuote(opf_path) .. " 2>/dev/null",
        1024 * 1024)
end

local _cache = {}

local function _statKey(filepath)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return "" end
    local attr = lfs.attributes(filepath)
    if type(attr) == "table" then
        return tostring(attr.modification or "") .. ":" .. tostring(attr.size or "")
    end
    local mtime = lfs.attributes(filepath, "modification")
    local size = lfs.attributes(filepath, "size")
    return tostring(mtime or "") .. ":" .. tostring(size or "")
end

local function _metadataForFile(filepath)
    local stat_key = _statKey(filepath)
    local cached = _cache[filepath]
    if cached and cached.stat_key == stat_key then return cached end

    local entry = { stat_key = stat_key }
    local ok, opf = pcall(_readOpfFromEpub, filepath)
    if ok and opf then
        entry.authors = EpubMetadata.extractAuthorCreatorsFromOpf(opf)
        entry.subtitle = EpubMetadata.extractSubtitleFromOpf(opf)
        entry.illustrator = EpubMetadata.extractIllustratorFromOpf(opf)
        entry.translator = EpubMetadata.extractTranslatorFromOpf(opf)
    end
    _cache[filepath] = entry
    return entry
end

function EpubMetadata.authorCreatorsForFile(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end

    return _copyList(_metadataForFile(filepath).authors)
end

function EpubMetadata.subtitleForFile(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end
    return _metadataForFile(filepath).subtitle
end

function EpubMetadata.illustratorForFile(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end
    return _metadataForFile(filepath).illustrator
end

function EpubMetadata.translatorForFile(filepath)
    if type(filepath) ~= "string" or not filepath:lower():match("%.epub$") then
        return nil
    end
    return _metadataForFile(filepath).translator
end

function EpubMetadata.invalidate(filepath)
    if filepath then
        _cache[filepath] = nil
    else
        _cache = {}
    end
end

return EpubMetadata
