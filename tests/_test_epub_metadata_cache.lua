-- Exercise the real keyed cache and OPF reader across simulated restarts.
package.path = "./?.lua;" .. package.path
local t = dofile("tests/_helpers.lua").runner()
local files, stat, commands, fail_read, fail_disk, now, opf, mkdirs
local original_popen, original_time = io.popen, os.time
local default_opf = [[<metadata>
    <dc:creator opf:role="aut">Author</dc:creator>
    <meta name="bookorbit:subtitle" content="Subtitle" />
    <meta name="calibre:series" content="Series" />
    <meta name="calibre:series_index" content="3" />
</metadata>]]
package.loaded["datastorage"] = { getDataDir = function() return "/cache-test" end }
package.loaded["libs/libkoreader-lfs"] = {
    mkdir = function() mkdirs = mkdirs + 1; return true end,
    attributes = function(_, key) return key and stat and stat[key] or stat end,
    dir = function(path)
        local names = {}
        for fp in pairs(files) do
            if fp:sub(1, #path) == path then names[#names + 1] = fp:sub(#path + 1) end
        end
        local i = 0
        return function() i = i + 1; return names[i] end
    end,
}
package.loaded["persist"] = { new = function(_, opts)
    return {
        load = function() if fail_disk then error("read failure") end; return files[opts.path] end,
        save = function(_, value)
            if fail_disk then error("write failure") end
            files[opts.path] = value; return true
        end,
        delete = function() files[opts.path] = nil end,
    }
end }
io.popen = function(cmd)
    commands = commands + 1
    if fail_read then error("unzip unavailable") end
    local data = cmd:find("META-INF/container.xml", 1, true)
        and '<container><rootfile full-path="OEBPS/content.opf"/></container>' or opf
    return { lines = function()
        local sent = false
        return function() if not sent then sent = true; return data end end
    end, close = function() end }
end
os.time = function() return now end
local function restart() return dofile("lib/bookshelf_epub_metadata.lua") end
local function reset()
    files, stat = {}, { modification = 100, size = 1000 }
    commands, mkdirs, now, fail_read, fail_disk, opf = 0, 0, 1000, false, false, default_opf
    return restart()
end

t.test("all fallback fields share one extraction, then survive restart without unzip", function()
    local m = reset()
    assert(m.authorCreatorsForFile("/a.epub")[1] == "Author")
    assert(m.subtitleForFile("/a.epub") == "Subtitle")
    local name, n = m.seriesForFile("/a.epub")
    assert(name == "Series" and n == "3" and commands == 2)
    m = restart()
    local authors = m.authorCreatorsForFile("/a.epub")
    authors[1] = "modified by caller"
    assert(m.authorCreatorsForFile("/a.epub")[1] == "Author")
    assert(m.subtitleForFile("/a.epub") == "Subtitle" and commands == 2)
end)

t.test("file size or mtime changes invalidate persisted metadata", function()
    local m = reset()
    m.subtitleForFile("/a.epub")
    stat.size = 1001
    assert(restart().subtitleForFile("/a.epub") == "Subtitle" and commands == 4)
    stat.modification = 101
    assert(restart().subtitleForFile("/a.epub") == "Subtitle" and commands == 6)
end)

t.test("successful absence of optional fields is persisted too", function()
    local m = reset()
    opf = "<metadata><dc:title>Plain book</dc:title></metadata>"
    assert(m.subtitleForFile("/a.epub") == nil)
    assert(restart().subtitleForFile("/a.epub") == nil and commands == 2)
end)

t.test("transient extraction failures retry and never poison disk cache", function()
    local m = reset()
    fail_read = true
    assert(m.subtitleForFile("/a.epub") == nil and next(files) == nil)
    local before = commands
    fail_read = false
    assert(m.subtitleForFile("/a.epub") == nil and commands == before)
    now = now + 61
    assert(m.subtitleForFile("/a.epub") == "Subtitle" and commands == before + 2)
    assert(restart().subtitleForFile("/a.epub") == "Subtitle" and commands == before + 2)
end)

t.test("single-book and global invalidation work across restart", function()
    local m = reset()
    m.subtitleForFile("/a.epub"); m.subtitleForFile("/b.epub")
    m = restart()
    m.invalidate("/a.epub")
    m.subtitleForFile("/b.epub")
    assert(commands == 4)
    m.subtitleForFile("/a.epub")
    assert(commands == 6)
    restart().invalidate()
    assert(next(files) == nil, "unread previous-session entries survived clear")
    restart().subtitleForFile("/b.epub")
    assert(commands == 8)
end)

t.test("missing stat and failing disk still allow metadata reads", function()
    local m = reset()
    stat = nil
    assert(m.subtitleForFile("/a.epub") == "Subtitle" and next(files) == nil)
    stat = { modification = 100, size = 1000 }
    fail_disk = true
    assert(restart().subtitleForFile("/a.epub") == "Subtitle")
    assert(next(files) == nil)
end)

t.test("wrong key, wrong schema, invalid fields and corrupt data are cache misses", function()
    for _, corrupt in ipairs{
        function(v) v.key = "/other.epub" end,
        function(v) v.version = -1 end,
        function(v) v.value.authors = { {} } end,
        function(v) v.value.subtitle = false end,
        function(v) v.value.stat_key = "outdated" end,
        function(v) v.value = "not a table" end,
    } do
        local m = reset()
        m.subtitleForFile("/a.epub")
        corrupt(select(2, next(files)))
        assert(restart().subtitleForFile("/a.epub") == "Subtitle" and commands == 4)
    end
end)

t.test("cache directories are created once per store, with isolated namespaces", function()
    reset()
    local Cache = require("lib/bookshelf_keyed_cache")
    local a, b = Cache.new("one", 1), Cache.new("two", 1)
    assert(a.write("same", { n = 1 }))
    assert(a.write("different", { n = 2 }))
    assert(mkdirs == 2, "each entry attempted directory creation")
    assert(b.write("same", { n = 3 }))
    assert(a.read("same").n == 1 and b.read("same").n == 3)
    files["/cache-test/cache/bookshelf/one/not-cache.txt"] = "keep"
    Cache.new("one", 1).clear()
    assert(not a.read("same") and b.read("same").n == 3)
    assert(files["/cache-test/cache/bookshelf/one/not-cache.txt"] == "keep")
end)

io.popen, os.time = original_popen, original_time
t.done()
