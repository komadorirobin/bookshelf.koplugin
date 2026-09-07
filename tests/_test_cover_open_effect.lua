-- tests/_test_cover_open_effect.lua
-- BookshelfWidget:_paintOpeningEffect draws the tapped cover's chrome ITSELF,
-- with its own arc scan and its own rounded-shadow repaint, rather than going
-- back through SpineWidget. That is deliberate (it is patching pixels already
-- on screen, mid-frame, with no widget to re-render), but it means the flat
-- cover options have to be honoured a second time, here, or opening a book
-- flashes back the rounded corners and drop shadow the reader turned off.
--
-- SOURCE-SHAPE checks, like tests/_test_list_row_budget.lua's: the function
-- paints into a live Screen.bb and cannot be driven under stubs, and there is
-- exactly one call site. Delete either guard and every other suite stays green
-- while the bug comes back.
package.path = "./?.lua;./?/init.lua;" .. package.path

local helpers = dofile("tests/_helpers.lua")
local t = helpers.runner()

local src = io.open("lib/bookshelf_widget.lua"):read("*a")
local body = src:match("\nfunction BookshelfWidget:_paintOpeningEffect%(fp%)\n(.-)\nend\n")

t.test("the function is still there under that name", function()
    assert(body, "_paintOpeningEffect is gone or its signature changed -- "
        .. "the guards below cannot be checked")
end)

t.test("the corner arc scan is skipped when corners are square", function()
    -- The scan whitens the pixels OUTSIDE the corner arc, to undo the black
    -- corner mask the selection ring needed. With square corners no mask ran,
    -- so there is nothing to undo and the scan would round off a square cover.
    assert(body:match("_squareCorners"),
        "the arc scan must consult _squareCorners, or a square cover gets its "
        .. "corners whitened on open")
end)

t.test("the rounded shadow repaint is skipped when the shadow is off", function()
    -- The repaint puts back a real drop shadow for a cover whose ring was just
    -- erased. With shadows off there was never one to put back.
    assert(body:match("_noShadow"),
        "the shadow repaint must consult _noShadow, or a flat cover grows a "
        .. "shadow on open")
end)

t.test("a spine-shelf face-out keeps the 3D flex despite flat_thumb", function()
    -- Face-out tiles set flat_thumb for the chrome (square corners, no
    -- shadow) but are full-size covers: routing them to the list
    -- thumbnail's flat squash lost the skew (user report). The branch must
    -- consult the tile's spine_face_out declaration.
    assert(body:match("spine_face_out"),
        "the flex/squash branch must exempt spine_face_out tiles, or shelf "
        .. "face-outs open with the flat thumbnail squash")
end)

t.test("a spine-mode open without a tapped tile hands off to the spine effect", function()
    -- Opens from a bare spine have no cover tile to flex; the spine tilt +
    -- hero flex live in _paintSpineOpeningEffect.
    assert(body:match("_paintSpineOpeningEffect"),
        "the no-tapped-tile branch must route spine-mode opens to "
        .. "_paintSpineOpeningEffect, or spines open with no feedback")
end)

t.test("the effect asks the tapped spine, not the settings directly", function()
    -- The spine knows about flat_thumb too: a list-view thumbnail is already
    -- flat whatever the grid preference says. Reading the settings here would
    -- lose that and re-round the list's cover column on open.
    assert(body:match("spine:_squareCorners") and body:match("spine:_noShadow"),
        "both guards must go through the tapped spine, so flat_thumb still wins")
    assert(not body:match('BookshelfSettings%.[a-zA-Z]+%("cover_square_corners"'),
        "do not read the corner setting directly here -- ask the spine")
    assert(not body:match('BookshelfSettings%.[a-zA-Z]+%("cover_no_shadow"'),
        "do not read the shadow setting directly here -- ask the spine")
end)

t.done()
