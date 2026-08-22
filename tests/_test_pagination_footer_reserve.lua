-- Regression coverage for the custom pagination margin controls. A negative
-- top margin shortens the footer's outer box, but the full-height child paints
-- above it; the shelf must reserve that visible area rather than the box alone.

local f = assert(io.open("lib/bookshelf_widget.lua", "r"))
local src = f:read("*a")
f:close()
local params, body = src:match(
    "local function _paginationFooterVisibleReserve%((.-)%)\n(.-)\nend")
assert(body, "visible reserve helper not found")
local visibleReserve = assert(load(
    "return function(" .. params .. ")\n" .. body .. "\nend",
    "pagination footer reserve", "t", { math = math }))()

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. name .. ": " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected)
    assert(actual == expected,
        string.format("expected %d, got %d", expected, actual))
end

test("default margins reserve the full footer", function()
    eq(visibleReserve(80, 0, 0), 80)
end)

test("negative top margin cannot hide painted footer height", function()
    eq(visibleReserve(80, -60, 0), 80)
end)

test("positive top margin remains intentional separation", function()
    eq(visibleReserve(80, 20, 0), 100)
end)

test("negative bottom margin may lower the footer toward the dock", function()
    eq(visibleReserve(80, 0, -20), 60)
end)

test("clamped outer box still accounts for an upward-shifted child", function()
    eq(visibleReserve(80, -60, -30), 61)
end)

-- Ensure the production implementation keeps using the same geometry rather
-- than regressing to `base + top + bottom` during a future merge.
test("widget uses visible footer reservation", function()
    local body = src:match(
        "function BookshelfWidget:_paginationFooterReserveHeight%(%)\n(.-)\nend")
    assert(body, "reserve method not found")
    assert(body:find("_paginationFooterVisibleReserve", 1, true),
        "reserve method no longer uses visible footer geometry")
end)

io.write(string.format(
    "pagination_footer_reserve: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
