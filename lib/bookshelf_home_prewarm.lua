-- Headless cache warming for launches from SimpleUI Home.
--
-- The destination profile is not known while Home is visible, so this module
-- warms shared repository state for both fixed profiles without creating a
-- hidden BookshelfWidget. Expensive cover and folder work is returned as
-- individual jobs; main.lua schedules those only while Home remains idle.

local M = {}

local function profileOrder(last_profile)
    if last_profile == "comics" then return { "comics", "prose" } end
    return { "prose", "comics" }
end

local function pageLimit()
    local Settings = require("lib/bookshelf_settings_store")
    local cols = tonumber(Settings.read("bookshelf_columns"))
    if not cols then
        local size = Settings.read("bookshelf_size") or "medium"
        cols = ({ small = 5, medium = 4, large = 3 })[size] or 4
    end
    local rows = tonumber(Settings.read("bookshelf_rows")) or 2
    return math.max(8, math.min(20, math.floor(cols) * math.floor(rows)))
end

local function coverTarget()
    local Device = require("device")
    local Settings = require("lib/bookshelf_settings_store")
    local cols = tonumber(Settings.read("bookshelf_columns"))
    if not cols then
        local size = Settings.read("bookshelf_size") or "medium"
        cols = ({ small = 5, medium = 4, large = 3 })[size] or 4
    end
    cols = math.max(2, math.min(10, math.floor(cols)))
    -- Deliberately a little larger than the real slot. The canonical cover
    -- cache can downscale a larger entry at paint time, while an undersized
    -- entry would force Bookshelf to decode the cover again.
    local w = math.max(1, math.floor(Device.screen:getWidth() / cols))
    local aspect = Settings.isTrue("true_cover_aspect") and 1.65 or 1.5
    return w, math.max(1, math.floor(w * aspect))
end

local function addRecordJobs(jobs, seen, record)
    if type(record) ~= "table" then return end
    local fp = record.filepath or record.fp
    if fp and not seen[fp] then
        seen[fp] = true
        jobs[#jobs + 1] = {
            kind = "cover",
            filepath = fp,
            cover_bb = record.cover_bb,
        }
    end
    -- The raw BIM cover is one-shot. Transfer ownership to the queued job so
    -- no hydrated record can later expose the same pointer to a real widget.
    record.cover_bb = nil
    addRecordJobs(jobs, seen, record.first_book)
    for _, book in ipairs(record.books or {}) do
        addRecordJobs(jobs, seen, book)
    end
    if record.kind == "folder" and record.path then
        local key = "folder:" .. record.path
        if not seen[key] then
            seen[key] = true
            jobs[#jobs + 1] = { kind = "folder", path = record.path }
        end
    end
end

function M.profileOrder(last_profile)
    return profileOrder(last_profile)
end

-- A cold getAll may return raw cover buffers even for a light request. Jobs
-- own those buffers until they run, so cancellation must release them.
function M.releaseJob(job)
    if type(job) ~= "table" then return end
    local bb = job.cover_bb
    job.cover_bb = nil
    if bb and bb.free then pcall(function() bb:free() end) end
end

-- Build the active profile's first-page shape/metadata cache and return
-- fine-grained follow-up jobs for covers and folder read-state summaries.
function M.fetchProfile(profile_key)
    local Profiles = require("lib/bookshelf_profiles")
    local Repo = require("lib/bookshelf_book_repository")
    local Settings = require("lib/bookshelf_settings_store")
    local profile = Profiles.get(profile_key)
    if not profile then return {} end

    local chip_key = Settings.read("active_chip_" .. profile.key)
        or Profiles.defaultChip(profile)
    local chip = Profiles.chip(profile, chip_key)
        or Profiles.chip(profile, Profiles.defaultChip(profile))
    if not chip then return {} end

    local limit = pageLimit()
    local scope = Profiles.scope(profile)
    local items = {}
    if chip.kind == "folder" then
        local sort = Profiles.folderSortPriority(profile)
        -- The zero-limit pass builds getAll's complete sorted shape cache
        -- without hydrating covers. The second call is then a cheap HIT that
        -- supplies only the visible page's filepaths/light metadata.
        Repo.getAll(chip.path, 0, 0, sort, nil, { light_only = true })
        items = Repo.getAll(chip.path, limit, 0, sort, nil, {
            light_only = true,
            lazy_cover = true,
        }) or {}
    elseif chip.kind == "authors" then
        items = Repo.getAuthors(limit, 0, nil, scope, nil, {
            light_only = true,
        }) or {}
    elseif chip.kind == "latest" then
        items = Repo.getLatest(limit, 0, scope, {
            light_only = true,
            lazy_cover = true,
        }) or {}
    elseif chip.kind == "next" then
        items = Repo.getNextUnreadInSeries(limit, 0, scope) or {}
    end

    local jobs, seen = {}, {}
    for _, item in ipairs(items) do addRecordJobs(jobs, seen, item) end
    return jobs, chip.key
end

-- Run one small follow-up job. Folder jobs return progress jobs which the
-- caller appends to the queue, keeping large manga folders interruptible.
function M.runJob(job)
    if type(job) ~= "table" then return {} end
    local Repo = require("lib/bookshelf_book_repository")
    if job.kind == "folder" then
        local ok, paths = pcall(Repo.getFolderBookPaths, job.path)
        local follow = {}
        if ok and type(paths) == "table" then
            for _, fp in ipairs(paths) do
                follow[#follow + 1] = { kind = "progress", filepath = fp }
            end
        end
        return follow
    end
    if job.kind == "progress" then
        pcall(Repo.readProgress, job.filepath)
        return {}
    end
    if job.kind ~= "cover" or not job.filepath then return {} end

    local Device = require("device")
    local Settings = require("lib/bookshelf_settings_store")
    local safe_mode = Device:isAndroid() and Settings.nilOrTrue("android_safe_mode")
    local bb = job.cover_bb
    job.cover_bb = nil
    if safe_mode then
        if bb and bb.free then pcall(function() bb:free() end) end
        return {}
    end

    local Cache = require("lib/bookshelf_scaled_cover_cache")
    if Cache:has(job.filepath) then
        if bb and bb.free then pcall(function() bb:free() end) end
        return {}
    end
    if not bb then
        local ok, fetched = pcall(Repo.getCoverBB, job.filepath)
        if ok then bb = fetched end
    end
    if not bb then return {} end

    local w, h = coverTarget()
    local ok_scale, scaled = pcall(function() return bb:scale(w, h) end)
    if ok_scale and scaled then pcall(Cache.put, Cache, job.filepath, scaled) end
    if bb.free then pcall(function() bb:free() end) end
    return {}
end

return M
