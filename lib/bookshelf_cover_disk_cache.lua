--[[--
Disk backing for ScaledCoverCache.

ScaledCoverCache is memory-only, so every launch re-derives every visible
cover: BookInfoManager hands back a compressed cover, we decompress it and
scale it to the slot. Measured on a PW5, a first render of the Series chip
spent ~900ms doing that for the ~24 covers of one page, about a quarter of a
3.5s cold start, and paid it again on the next launch.

The covers are already persisted -- in BIM's database -- so this does not
store anything new. It stores the RESULT: the scaled blitbuffer, raw, so a
later launch reads it back instead of decompressing and rescaling. Reading a
262x393 8bpp buffer off the PW5 measured 2.9ms against ~37ms to rebuild it.

Deliberately dumb about correctness. Every way a cover can change already
funnels through ScaledCoverCache:drop (the stale sweep, and the widget when
BIM finishes a fresh extraction) or :clear (a cover-size settings change), so
this mirrors those and owns no invalidation logic of its own. On top of that
each file carries the filepath and geometry it was written for and is rejected
if either disagrees, which turns a hash collision or a half-written file into
a miss rather than a wrong cover on screen.
]]--

local lfs = require("libs/libkoreader-lfs")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local M = {}

local MAGIC = "BSC1"
-- Bounded in BYTES, for the reason ScaledCoverCache gives for bounding RAM
-- the same way: entry size varies ~5x between a shelf cover and a hero one and
-- ~4x between 8bpp grayscale and RGB32, so a file COUNT maps to wildly
-- different amounts of disk. The sweep already stats each file for its mtime;
-- taking the size from the same call makes the byte bound free.
-- 96MB (was 32). One page of shelf covers is ~2.4MB, so this holds ~40 pages
-- -- enough that a deep paging session survives a restart instead of paying
-- the decode+scale again for everything beyond the first dozen pages (the
-- post-restart "first visit to every page is slow" report). Still a cache,
-- not a mirror of the library, and still modest next to BIM's cover
-- database -- the largest thing bookshelf touches on a Kindle.
M.MAX_BYTES = 96 * 1024 * 1024

local _dir            -- resolved cache directory, or false when unavailable
local _entries, _bytes, _indexed = {}, 0, false
local _task, _dir_handle
local _active = true
local _write_generation = 0

local function record(path, size, mtime)
    local old = _entries[path]
    _bytes = _bytes - (old and old.b or 0) + (size or 0)
    _entries[path] = size and { p = path, b = size, m = mtime or 0 } or nil
end

local function cancelMaintenance()
    if _task then
        _task.ui:unschedule(_task.tick)
        _task = nil
    end
    if _dir_handle then
        pcall(function() _dir_handle:close() end)
        _dir_handle = nil
    end
end

local function dir()
    if _dir ~= nil then return _dir or nil end
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage and DataStorage.getDataDir) then
        _dir = false
        return nil
    end
    local d = DataStorage:getDataDir() .. "/cache/bookshelf_covers"
    if lfs.attributes(d, "mode") ~= "directory" then
        local ok_mk = pcall(lfs.mkdir, d)
        if not ok_mk or lfs.attributes(d, "mode") ~= "directory" then
            _dir = false
            return nil
        end
    end
    _dir = d
    return d
end

-- djb2 over the path. Multiplication and addition only: KOReader runs LuaJIT,
-- which is Lua 5.1, where the binary `~` xor operator does not exist (it
-- parses on newer LuaJIT builds and on the 5.4 interpreter the tests use,
-- which is exactly why the mistake would have survived to the device). The
-- intermediate stays under 2^53, so it is exact in a double.
--
-- Only has to spread filenames across a directory. Book paths share long
-- prefixes, so trailing bytes -- where they actually differ -- dominate. A
-- collision is caught by the filepath stored in the file header.
local function keyFor(filepath)
    local h = 5381
    for i = 1, #filepath do
        h = (h * 33 + filepath:byte(i)) % 4294967296
    end
    return string.format("%08x_%d", h, #filepath)
end

local function pathFor(filepath)
    local d = dir()
    if not d then return nil end
    return d .. "/" .. keyFor(filepath)
end

-- The book a cache file was written for, without reading its pixels. Used only
-- by the over-budget branch of the sweep, so the common case never pays it.
local function bookOf(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local header = f:read("*l")
    local fp
    if header then
        local magic, _w, _h, _s, _t, fplen =
            header:match("^(%S+) (%d+) (%d+) (%d+) (%d+) (%d+)$")
        if magic == MAGIC then fp = f:read(tonumber(fplen) or 0) end
    end
    f:close()
    return fp
end

-- Index existing files once, then account for every store/drop. Automatic
-- maintenance yields between small batches of filesystem operations.
local function sweep(yield_step)
    yield_step = yield_step or function() end
    local d = dir()
    if not d then return end
    if not _indexed then
        local iter, handle = lfs.dir(d)
        _dir_handle = handle
        for entry in iter, handle do
            if entry ~= "." and entry ~= ".." then
                local p = d .. "/" .. entry
                local a = lfs.attributes(p) or {}
                if a.mode == "file" then record(p, a.size, a.modification) end
                yield_step()
            end
        end
        _dir_handle = nil
        _indexed = true
    end
    if _bytes <= M.MAX_BYTES then return end
    local entries = {}
    for _, entry in pairs(_entries) do entries[#entries + 1] = entry end
    -- Over budget. Before falling back to age, drop covers whose book is no
    -- longer there: those can never be used again, while an old cover for a
    -- book still on the shelf may well be wanted on the next launch.
    --
    -- This is the ONLY place that check happens, deliberately. Dropping a
    -- deleted book's cover eagerly (say, from the stale sweep, which already
    -- knows which files have gone) would churn every session for anyone whose
    -- library lives on removable media: unmounted reads as deleted, and the
    -- covers would be discarded and rebuilt on every mount. Doing it only when
    -- space is actually short means an unmounted card costs nothing until the
    -- cache is full, and even then it costs a rebuild rather than a wrong
    -- cover.
    local orphans = 0
    for i = 1, #entries do
        local fp = bookOf(entries[i].p)
        -- No readable header is its own kind of orphan: nothing can use it.
        entries[i].orphan = (fp == nil) or (lfs.attributes(fp, "mode") == nil)
        if entries[i].orphan then orphans = orphans + 1 end
        yield_step()
    end
    table.sort(entries, function(a, b)
        if a.orphan ~= b.orphan then return a.orphan end   -- orphans first
        return a.m < b.m                                    -- then oldest
    end)
    local pruned = 0
    for i = 1, #entries do
        if _bytes <= M.MAX_BYTES then break end
        local entry = entries[i]
        -- A foreground render may have replaced this file while we yielded.
        if _entries[entry.p] == entry then
            local ok, removed = pcall(os.remove, entry.p)
            if (ok and removed) or lfs.attributes(entry.p, "mode") == nil then
                record(entry.p, nil)
                pruned = pruned + 1
            end
        end
        yield_step()
    end
    logger.dbg(string.format(
        "[bookshelf] cover disk cache: pruned %d of %d files (%d orphaned), now %d KB",
        pruned, #entries, orphans, math.floor(_bytes / 1024)))
end

-- Explicit maintenance stays synchronous for tools/tests. Normal writes only
-- queue bounded I/O steps; the byte ledger includes writes between steps.
function M.sweep()
    cancelMaintenance()
    _entries, _bytes, _indexed = {}, 0, false
    local ok, err = pcall(sweep)
    if not ok then
        cancelMaintenance()
        logger.warn("[bookshelf] cover cache sweep:", err)
    end
end

local function maybeSweep()
    if not _active or _task or (_indexed and _bytes <= M.MAX_BYTES) then return end
    local ok, ui = pcall(require, "ui/uimanager")
    if not ok or not ui.scheduleIn or not ui.unschedule then return end
    local task = { ui = ui, generation = _write_generation }
    local co = coroutine.create(function()
        local operations = 0
        sweep(function()
            operations = operations + 1
            if operations >= 8 then operations = 0; coroutine.yield() end
        end)
    end)
    _task = task
    task.tick = function()
        if _task ~= task then return end
        local resumed, err = coroutine.resume(co)
        if not resumed or coroutine.status(co) == "dead" then
            cancelMaintenance()
            if not resumed then logger.warn("[bookshelf] cover cache sweep:", err) end
            -- A render can add files after this sweep built its candidate
            -- list. Retry for those writes, but never spin on failed deletes.
            if resumed and task.generation ~= _write_generation then maybeSweep() end
        else
            ui:scheduleIn(0.02, task.tick)
        end
    end
    ui:scheduleIn(0.05, task.tick)
end

function M.setActive(active)
    _active = active == true
    if _active then maybeSweep() else cancelMaintenance() end
end

--- Write a scaled cover. Returns true when it landed on disk.
function M.store(filepath, bb)
    if type(filepath) ~= "string" or filepath == "" or not bb then return false end
    local p = pathFor(filepath)
    if not p then return false end
    local size, file
    local tmp = p .. ".tmp"
    local ok = pcall(function()
        local ffi = require("ffi")
        local w, h = bb:getWidth(), bb:getHeight()
        local stride = tonumber(bb.stride)
        local btype  = tonumber(bb:getType())
        if not (w and h and stride and btype) or w <= 0 or h <= 0 then
            error("unusable blitbuffer")
        end
        -- Refuse anything Blitbuffer.new(w, h, type, nil, stride) would not
        -- reproduce exactly. The header carries w, h, stride and type, and the
        -- reader rebuilds from those alone, so a buffer holding state outside
        -- that set must be a miss rather than a subtly wrong cover.
        --
        -- Two things live outside it. pixel_stride is derived from stride and
        -- bpp on the way back in, so a buffer whose own pixel_stride disagrees
        -- would come back reshaped. Rotation and inversion live in the config
        -- byte, which the header has nowhere to put, and an inverted cover
        -- reloaded as a normal one is a photo negative on the shelf.
        --
        -- Note this does NOT reject viewport buffers, and does not need to: a
        -- viewport keeps its parent's stride, so its extra columns sit beyond
        -- w and are never painted, and its rows round-trip as they are.
        local bpp = Blitbuffer.TYPE_TO_BPP and Blitbuffer.TYPE_TO_BPP[btype]
        if not bpp then error("unknown buffer type") end
        if tonumber(bb.pixel_stride) ~= math.floor(stride * 8 / bpp) then
            error("non-derivable pixel stride (viewport or padded buffer)")
        end
        if (bb.getRotation and bb:getRotation() or 0) ~= 0 then error("rotated") end
        if (bb.getInverse  and bb:getInverse()  or 0) ~= 0 then error("inverted") end
        -- Write to a sibling and rename, so a crash mid-write cannot leave a
        -- truncated file that later reads as a valid header with short data.
        local f = assert(io.open(tmp, "wb"))
        file = f
        local header = string.format("%s %d %d %d %d %d\n%s\n",
            MAGIC, w, h, stride, btype, #filepath, filepath)
        assert(f:write(header))
        assert(f:write(ffi.string(bb.data, stride * h)))
        assert(f:close())
        file = nil
        assert(os.rename(tmp, p))
        size = #header + stride * h
    end)
    if ok then
        record(p, size, os.time())
        _write_generation = _write_generation + 1
        maybeSweep()
    else
        if file then pcall(file.close, file) end
        os.remove(tmp)
    end
    return ok
end

--- Read a scaled cover back, or nil. Never returns a buffer for a different
--- book or a different geometry than it was written with.
function M.load(filepath)
    if type(filepath) ~= "string" or filepath == "" then return nil end
    local p = pathFor(filepath)
    if not p then return nil end
    local ok, bb = pcall(function()
        local f = io.open(p, "rb")
        if not f then return nil end
        local header = f:read("*l")
        if not header then f:close(); return nil end
        local magic, w, h, stride, btype, fplen =
            header:match("^(%S+) (%d+) (%d+) (%d+) (%d+) (%d+)$")
        if magic ~= MAGIC then f:close(); return nil end
        w, h, stride, btype, fplen =
            tonumber(w), tonumber(h), tonumber(stride), tonumber(btype), tonumber(fplen)
        local stored_fp = f:read(fplen)
        f:read(1)  -- the newline after the path
        if stored_fp ~= filepath then f:close(); return nil end   -- hash collision
        local want = stride * h
        local data = f:read(want)
        f:close()
        if not data or #data ~= want then return nil end           -- truncated
        local out = Blitbuffer.new(w, h, btype, nil, stride)
        if not out then return nil end
        local ffi = require("ffi")
        ffi.copy(out.data, data, want)
        return out
    end)
    return ok and bb or nil
end

function M.drop(filepath)
    local p = pathFor(filepath)
    if p then
        local ok, removed = pcall(os.remove, p)
        if (ok and removed) or not lfs.attributes(p, "mode") then record(p, nil) end
    end
end

function M.clear()
    cancelMaintenance()
    local d = dir()
    if not d then return end
    pcall(function()
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then pcall(os.remove, d .. "/" .. entry) end
        end
    end)
    _entries, _bytes, _indexed = {}, 0, false
end

return M
