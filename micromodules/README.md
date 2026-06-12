# Bookshelf micro-modules

Each `.lua` file here is one micro-module: a small read-only info panel.
The file must return a spec table:

```lua
return {
    key   = "my_module",          -- stable id stored in user menus
    title = _("My module"),       -- shown in the Add dialog
    render = function(width) ... end, -- return a widget (or nil to show a muted fallback)
    on_tap = function(ctx) ... end,   -- optional tap action
    keep_open = true,                 -- optional: tap acts without closing the menu
                                      -- (or a function(ctx) -> bool, resolved at tap time)
    show_settings = function(ctx) ... end, -- optional settings dialog
}
```

`on_tap` receives a context table `ctx = { bw = <bookshelf widget>,
menu = <start menu instance> }`; modules that ignore the argument keep
working. By default a tap closes the menu and then runs `on_tap`. With
`keep_open = true` the menu stays open: `on_tap(ctx)` runs first, then the
menu reloads so the module re-renders its new state (see `random_unread.lua`,
which loads a book into the hero behind the menu and re-rolls on each tap).
`keep_open` may also be a `function(ctx) -> bool` evaluated at tap time, for
modules whose settings decide per-tap whether the menu stays (see
`quote_of_day.lua`).

The loader exports `menu_generation`, a counter the start menu bumps once
per menu open — modules may key per-open caches on it (it is stable across
the menu's focus-step rebuilds, unlike a TTL).

`show_settings(ctx)` (same ctx shape) adds a "Module settings…" row to the
module's long-press dialog. The module owns the settings UI (typically a
ButtonDialog) and persistence, and calls `ctx.menu:_reload()` after changes
so the card re-renders. Convention: store settings via
`require("lib/bookshelf_settings_store")` under `micromodule_<key>_*` keys
(see `clock.lua` for a minimal example).

If your render output includes a `TextBoxWidget`, set its `bgcolor` to
`require("lib/bookshelf_start_menu_modules").CARD_BG` - the shared grey the
module card is painted with - or the text sits on a white bar.

Files are discovered at runtime; invalid specs are logged and skipped, and
`render` is pcall'd, so a broken module never breaks the menu. Keep `render`
fast - it runs on every menu paint, so cache anything slow (see
`reading_stats.lua` for a TTL-cached sqlite read). On failure, return nil.

New modules are welcome as drop-in contributions - one file, no other changes.
