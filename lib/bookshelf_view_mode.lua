-- bookshelf_view_mode.lua
-- Which presentation the shelf grid uses: covers or list.
--
-- Deliberately a pure function of its inputs rather than state anywhere, so
-- the whole decision is testable headless and there is exactly one place that
-- answers "which mode am I in".
--
-- ── THE MODEL: a chip pin, defaulting to AUTO ──────────────────────────────
--
-- A chip is pinned to LIST, pinned to COVERS, or set to AUTO. In this fork,
-- UNSET also means AUTO so existing profiles retain their established
-- behaviour when upstream changes its default: covers at the top level and a
-- list after drilling into a folder or stack. Auto may also be stored
-- explicitly, and its policy is fixed:
--
--     expanded, or drilled into a folder / series / author / tag  ->  LIST
--     collapsed at a chip's top level                             ->  COVERS
--
-- This replaces the three independent booleans (list_when_expanded /
-- _collapsed / _in_folder) on the maintainer's ruling: "I think we can move
-- the 'show as list ...' options from the main menu into the per chip
-- settings ... as part of the show as 'list / covers / auto: list when
-- expanded or lists inside folders'". The policy Auto encodes is that quote,
-- verbatim. The old keys stay on disk, ignored -- list mode never shipped, so
-- nothing is owed to them.
--
-- Why that split earns being the ONE automatic behaviour: collapsed under the
-- hero there are two rows, where covers say more per item than text; expanded
-- and inside folders the reader is scanning MANY items, which is what a table
-- is for.

local ViewMode = {}

ViewMode.COVERS = "covers"
ViewMode.LIST   = "list"
ViewMode.AUTO   = "auto"

-- effective(expanded, in_folder) -> ViewMode.COVERS | ViewMode.LIST
--
-- The Auto policy, whole: a list wherever the reader is scanning many items
-- (expanded, or drilled into anything), covers on the two rows under the
-- hero. A pinned chip never reaches this -- the caller checks the pin first.
function ViewMode.effective(expanded, in_folder)
    if expanded or in_folder then return ViewMode.LIST end
    return ViewMode.COVERS
end

function ViewMode.isList(mode) return mode == ViewMode.LIST end

-- ── THE PER-CHIP OVERRIDE ──────────────────────────────────────────────────
--
-- A chip may pin itself to either mode, outranking the Auto policy.
-- Stored as tab.view_mode, persisted with the rest of the chip by
-- TabModel.save, and edited in the same picker as the chip's folder tile style
-- -- as its own SECTION of that picker, not as extra values in it.
--
-- The two were briefly one field, with "list" living among the tile styles.
-- The maintainer split them, and the reason is that they are genuinely
-- independent: a chip needs to be able to say "divider cards" without also
-- asserting a view mode, and "always a list" without throwing away the tile
-- style it would use if it ever showed tiles again. Merged, every tile style
-- silently meant "and never a list here", which also quietly reinterpreted
-- every chip in every existing library -- group_display has shipped for
-- several releases.
--
-- UNSET is the fourth state and the fork default: AUTO. Absence rather than a
-- sentinel keeps existing profiles on the automatic policy, while AUTO is
-- also accepted as an explicit stored value alongside the other two.
-- No labels here, and no gettext require: this file is a pure function of its
-- arguments so the whole decision is testable headless, and pulling in i18n for
-- three strings would end that. The chip editor owns the wording.
ViewMode.CHIP_KEY = "view_mode"

-- chipOverride(value) -> COVERS | LIST | AUTO | nil
--
-- nil for anything this build does not recognise -- including the absence
-- that means the automatic default -- so a hand-edited chip, or one written
-- by a later release, falls back safely rather than reaching a renderer as a
-- mode it has no branch for.
function ViewMode.chipOverride(value)
    if value == ViewMode.LIST or value == ViewMode.COVERS
            or value == ViewMode.AUTO then
        return value
    end
    return nil
end

return ViewMode
