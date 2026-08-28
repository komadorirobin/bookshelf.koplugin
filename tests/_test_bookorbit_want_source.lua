-- tests/_test_bookorbit_want_source.lua

package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }
package.loaded["logger"] = { warn = function() end }

local cached = {
    "/storage/emulated/0/ePubs/Fiktion/a.epub",
    "/storage/emulated/0/ePubs/Manga/b.epub",
    "/storage/emulated/0/ePubs/Fiktion/a.epub",
}
package.loaded["sui_store"] = {
    readSetting = function(_, key)
        assert(key == "simpleui_bookorbit_want_files")
        return cached
    end,
}

local Source = dofile("lib/bookshelf_bookorbit_want_source.lua")
local files, revision = Source.snapshot()
assert(#files == 2, "duplicate paths should be removed")
assert(files[1]:match("Fiktion") and files[2]:match("Manga"))
assert(type(revision) == "string" and revision:match("^2:"))

cached = { files[2] }
local files2, revision2 = Source.snapshot()
assert(#files2 == 1 and revision2 ~= revision,
    "live SimpleUI membership changes must produce a new source revision")

io.write("\n3 passed, 0 failed\n")
