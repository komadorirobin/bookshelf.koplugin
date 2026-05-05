-- shelf_row.lua
-- A single shelf: 4 horizontally-arranged spine slots + dotted base rule.
-- Each slot can be a SpineWidget (single book) or a SeriesStack (series group).
-- Empty slots render as blank spacers so the row always has a fixed width.
--
-- The dotted base rule is a custom-painted Widget subclass. Its paintTo method
-- walks pixel columns 3dp apart and draws a 1×thickness fillRect at each stop.
-- Pattern reference: bookends_overlay_widget.lua lines 176–185 (MultiLineWidget).

local FrameContainer  = require("ui/widget/container/framecontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Widget          = require("ui/widget/widget")
local Geom            = require("ui/geometry")
local Size            = require("ui/size")
local Blitbuffer      = require("ffi/blitbuffer")
local SpineWidget     = require("spine_widget")
local SeriesStack     = require("series_stack")
local FolderStack     = require("folder_stack")

local ShelfRow = {}

-- _renderDottedRule(width, thickness)
-- Returns a Widget subclass instance that paints a dotted horizontal rule via
-- bb:fillRect. Dot spacing is 3dp (1dp dot, 2dp gap). Uses COLOR_BLACK.
function ShelfRow._renderDottedRule(width, thickness)
    local DottedRule = Widget:extend{}

    function DottedRule:init()
        self.dimen = Geom:new{ w = width, h = thickness }
    end

    function DottedRule:paintTo(bb, x, y)
        -- Walk across the width placing 1×thickness filled rects every 3px.
        for px = 0, width - 1, 3 do
            bb:paintRect(x + px, y, 1, thickness, Blitbuffer.COLOR_BLACK)
        end
    end

    return DottedRule:new{}
end

-- ShelfRow.new(opts)
-- opts: {
--   width         number   total row width in pixels
--   height        number   slot height in pixels
--   items         table    list of up to 4 Book or SeriesGroup records (nil = empty slot)
--   gap           number   (optional) pixel gap between slots (default Size.padding.default)
--   on_book_tap   function (book) callback
--   on_book_hold  function (book) callback
--   on_series_tap function (series) callback
--   on_series_hold function (series) callback
--   selected_filepath string|nil  filepath of the spine that should
--                                 render with the selected (thicker)
--                                 border. Typically the previewed book.
-- }
function ShelfRow.new(opts)
    local n_slots = 4
    -- Generous gap between covers so the shelf doesn't read as cramped.
    -- Size.padding.fullscreen × 2 ≈ 30dp at native scaling.
    local gap     = opts.gap or Size.padding.fullscreen * 2
    local slot_w  = math.floor((opts.width - gap * (n_slots - 1)) / n_slots)
    -- Standard 2:3 book-cover aspect (slot_w * 1.5) so covers look like books.
    local slot_h  = math.floor(slot_w * 1.5)
    local row     = HorizontalGroup:new{}

    for i = 1, n_slots do
        -- Insert a gap spacer before every slot after the first.
        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end

        local item = opts.items and opts.items[i]
        if item and item.kind == "folder" then
            -- Folder record (carries path / label / first_book)
            row[#row + 1] = FolderStack:new{
                folder      = item,
                width       = slot_w,
                height      = slot_h,
                on_tap      = opts.on_folder_tap,
                on_hold     = opts.on_folder_hold,
                is_selected = opts.selected_filepath and item.first_book
                              and item.first_book.filepath == opts.selected_filepath,
            }
        elseif item and item.books then
            -- SeriesGroup (has a .books array)
            row[#row + 1] = SeriesStack:new{
                series    = item,
                width     = slot_w,
                height    = slot_h,
                on_tap    = opts.on_series_tap,
                on_hold   = opts.on_series_hold,
            }
        elseif item then
            -- Single book record
            row[#row + 1] = SpineWidget:new{
                book        = item,
                width       = slot_w,
                height      = slot_h,
                on_tap      = opts.on_book_tap,
                on_hold     = opts.on_book_hold,
                is_selected = opts.selected_filepath
                              and item.filepath == opts.selected_filepath,
            }
        else
            -- Empty slot — a bare Widget with a sized dimen. FrameContainer
            -- crashes on getSize() when its self[1] child is nil, so we use
            -- the lighter-weight Widget directly. Widget:getSize() returns
            -- self.dimen, which gives the row a stable slot footprint.
            row[#row + 1] = Widget:new{
                dimen = Geom:new{ w = slot_w, h = slot_h },
            }
        end
    end

    -- Shelf base rule removed (read as visual noise rather than support).
    -- Just return the slot row directly.
    return row
end

return ShelfRow
