-- tests/_test_series_author_sort.lua
-- Sorting a shelf of GROUPS by author uses the members' author, not the
-- group's display name (issue #351).
--
-- Run from the plugin root: `lua tests/_test_series_author_sort.lua`
--
-- THE BUG. A series stack is { series_name = "The Expanse", books = {...} }:
-- it carries its members but no author of its own. The fallback chain in
-- cachedSurname reached b.series_name and handed the SERIES TITLE to
-- surnameSortKey, which parsed the last word of the title as a person's
-- surname. So "sort by author surname" on a series shelf ordered by the last
-- word of each series name -- "The Expanse" filed under E, "Discworld" under
-- D -- which looks alphabetical enough to miss, and is not the requested
-- ordering at all.
--
-- The nasty part is that it never errors and never looks obviously wrong: a
-- list sorted by the wrong string is still a sorted list.

package.loaded["logger"] = { dbg = function() end, info = function() end,
                              warn = function() end, err = function() end }
package.preload["lib/bookshelf_author_name"] = function()
    return dofile("lib/bookshelf_author_name.lua")
end
local SortEngine = dofile("lib/bookshelf_sort_engine.lua")

package.path = "./?.lua;./?/init.lua;" .. package.path
local helpers = dofile("tests/_helpers.lua")
local t  = helpers.runner()
local eq = helpers.eq

local function series(name, authors)
    local books = {}
    for i, a in ipairs(authors) do books[i] = { author = a } end
    return { series_name = name, books = books }
end

local function surname(rec) return SortEngine.sortKeyValue(rec, "author_surname") end

t.test("a series sorts under its author, not its title", function()
    -- "The Expanse" by James S. A. Corey. Reading the title gives "expanse";
    -- the members give "corey".
    eq(surname(series("The Expanse", { "James S. A. Corey", "James S. A. Corey" })),
       "corey", "the series title was parsed as an author name")
end)

t.test("a one-word series title is wrong in the same way", function()
    -- The reporter's shelf is full of these, and "Discworld" -> "discworld"
    -- reads like a plausible sort key, which is why it survived.
    eq(surname(series("Discworld", { "Terry Pratchett" })), "pratchett")
end)

t.test("a guest author on one volume does not move the series", function()
    -- The MODAL author, not the first and not the last. This is the case the
    -- reporter raised: a series should stay put when one volume is a
    -- collaboration.
    eq(surname(series("Long Earth", {
        "Terry Pratchett", "Terry Pratchett", "Stephen Baxter",
    })), "pratchett")
end)

t.test("the member order does not decide the answer", function()
    -- Taking books[1] would make the key depend on within-series ordering,
    -- so the same shelf could sort differently after a re-read reordered it.
    local a = surname(series("S", { "Guest Writer", "Main Author", "Main Author" }))
    local b = surname(series("S", { "Main Author", "Main Author", "Guest Writer" }))
    eq(a, b, "the sort key moved when the members were reordered")
    eq(a, "author")
end)

t.test("Calibre's author_sort still wins on the members", function()
    -- author_sort is the curated form and beats the parsed one, per the
    -- record-level chain; members are read in the same preference order so a
    -- library carrying it everywhere does not split one author across two
    -- spellings.
    local rec = { series_name = "Whatever", books = {
        { author = "Ursula K. Le Guin", author_sort = "Le Guin, Ursula K." },
        { author = "Ursula K. Le Guin", author_sort = "Le Guin, Ursula K." },
    } }
    eq(surname(rec), "guin", "the curated author_sort was ignored")
end)

t.test("a book's own author still wins over its group's", function()
    -- Rungs 1-3 come first: a record that knows its own author must not be
    -- overridden by anything derived from members.
    local rec = { author = "Iain M. Banks", series_name = "Culture",
                  books = { { author = "Someone Else" } } }
    eq(surname(rec), "banks")
end)

t.test("an author card is unchanged", function()
    -- Its display name IS a person, and every member shares that author, so
    -- the modal is the same answer the old path gave by parsing the label.
    eq(surname(series("Richard Osman", { "Richard Osman", "Richard Osman" })),
       "osman")
end)

t.test("a group with no member authors falls back to its name", function()
    -- Nothing to derive from, so the old behaviour stands rather than
    -- collapsing every such group onto one key.
    eq(surname({ series_name = "Some Series", books = { {}, {} } }), "series")
    eq(surname({ series_name = "Some Series" }), "series")
end)

t.done()
