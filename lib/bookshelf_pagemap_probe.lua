-- bookshelf_pagemap_probe.lua
-- Publisher page numbers straight out of an EPUB's zip -- no document load,
-- no render. KOReader's "reference page numbers" (ReaderPageMap) come from
-- the same structures crengine reads after a full load; this probe reads
-- them with libarchive + string matching in a few milliseconds instead,
-- so the bulk page-count scan can serve print-true counts for every book
-- that ships one (user insight: "publisher page numbers").
--
-- Three places a page list can live, probed in fidelity order:
--   1. EPUB3 nav document:  <nav epub:type="page-list"> <li><a…> per page
--   2. EPUB2 NCX:           <pageList> <pageTarget…>    per page
--   3. Adobe page-map.xml:  <spine page-map="id">, <page…> per page
-- The COUNT of targets is the page count -- robust against roman-numeral
-- front matter, which a max-of-labels reading would trip over.
--
-- Everything is pcall-guarded and returns nil on any surprise: a book the
-- probe cannot answer just falls through to the scanner's heavier paths.

local logger = require("logger")

local M = {}

local function urldecode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

-- Resolve `rel` against the directory of the OPF, folding "./" and "../"
-- (zip keys are plain forward-slash paths, never rooted).
local function dirjoin(dir, rel)
    if rel:sub(1, 1) == "/" then rel = rel:sub(2); dir = "" end
    local path = (dir ~= "" and (dir .. "/") or "") .. rel
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function countIn(content, patt)
    local n = 0
    for _ in content:gmatch(patt) do n = n + 1 end
    return n
end

-- publisherPages(filepath) -> pages, source | nil
-- source is "page-list", "ncx" or "page-map" for the log line.
function M.publisherPages(filepath)
    if type(filepath) ~= "string"
            or not filepath:lower():match("%.epub$") then
        return nil
    end
    local ok, pages, source = pcall(function()
        local Archiver = require("ffi/archiver")
        local rd = Archiver.Reader:new()
        if not rd:open(filepath) then return nil end
        -- Index every entry once so extractToMemory's seek() can find keys
        -- in any order (the reader indexes lazily as it iterates).
        for _ in rd:iterate() do end -- luacheck: ignore
        local function slurp(key)
            if not (key and rd.entries[key]) then return nil end
            return rd:extractToMemory(key)
        end
        local function done(n, src)
            pcall(function() rd:close() end)
            return n, src
        end

        local container = slurp("META-INF/container.xml")
        local opf_path = container
                         and container:match('full%-path%s*=%s*"([^"]+)"')
        if not opf_path then return done(nil) end
        opf_path = urldecode(opf_path)
        local opf = slurp(opf_path)
        if not opf then return done(nil) end
        local opf_dir = opf_path:match("^(.*)/[^/]+$") or ""

        -- Manifest items; attribute order varies, so match the tag then
        -- pick attributes out of it.
        local items = {}
        for tag in opf:gmatch("<item[%s][^>]*>") do
            local id = tag:match('%sid%s*=%s*"([^"]-)"')
            local href = tag:match('%shref%s*=%s*"([^"]-)"')
            if id and href then
                items[id] = {
                    href  = urldecode(href),
                    props = tag:match('%sproperties%s*=%s*"([^"]-)"') or "",
                    media = tag:match('%smedia%-type%s*=%s*"([^"]-)"') or "",
                }
            end
        end

        -- 1. EPUB3 nav page-list.
        for _id, it in pairs(items) do
            if it.props:find("nav", 1, true) then
                local nav = slurp(dirjoin(opf_dir, it.href))
                if nav then
                    local s = nav:find('type%s*=%s*"page%-list"')
                              or nav:find("type%s*=%s*'page%-list'")
                    if s then
                        local e = nav:find("</nav", s, true) or #nav
                        local n = countIn(nav:sub(s, e), "<a[%s>]")
                        if n > 0 then return done(n, "page-list") end
                    end
                end
            end
        end
        -- 2. EPUB2 NCX pageList.
        for _id, it in pairs(items) do
            if it.media == "application/x-dtbncx+xml" then
                local ncx = slurp(dirjoin(opf_dir, it.href))
                if ncx then
                    local n = countIn(ncx, "<pageTarget[%s/>]")
                    if n > 0 then return done(n, "ncx") end
                end
            end
        end
        -- 3. Adobe page-map.
        local pm_id = opf:match('<spine[^>]*page%-map%s*=%s*"([^"]-)"')
        local pm = pm_id and items[pm_id]
        if pm then
            local pmx = slurp(dirjoin(opf_dir, pm.href))
            if pmx then
                local n = countIn(pmx, "<page[%s/>]")
                if n > 0 then return done(n, "page-map") end
            end
        end
        return done(nil)
    end)
    if not ok then
        logger.dbg("[bookshelf] pagemap probe failed:", tostring(pages))
        return nil
    end
    if pages then
        logger.dbg(string.format("[bookshelf] pagemap probe: %d pages (%s) %s",
            pages, tostring(source), filepath))
    end
    return pages, source
end

return M
