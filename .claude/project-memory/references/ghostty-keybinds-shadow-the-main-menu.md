---
name: "libghostty keybinds shadow the main menu"
description: "A ⌘ combo libghostty binds is consumed by the focused surface, so a menu item on that combo acts only if LayoutActionHandler claims the action"
type: reference
---

# libghostty keybinds shadow the main menu

`GhosttySurfaceView.performKeyEquivalent` runs **ahead of the main menu**:
AppKit offers a ⌘ combo to the key window's view hierarchy before it consults
the menu bar. The view forwards every ⌘ combo to libghostty while the surface
is first responder and returns libghostty's consumed flag, so a combo
libghostty binds itself is swallowed there and the menu item carrying the same
shortcut never fires. The keystroke then does whatever Casper does with the
decoded action — nothing at all, if no handler claims it.

The pinned libghostty's macOS defaults bind `super+n` → `new_window`,
`super+t` → `new_tab`, `super+d` → `new_split:right` and `super+shift+d` →
`new_split:down`, which is why Casper's menu shortcuts on those combos work only
through `CasperUI.LayoutActionHandler`: it maps each decoded action onto the
nearest Casper concept (`.newWindow` → "New Workspace…", the Workspace menu's
⌘N item, `.newTab` → a split, `.newSplit` → the matching split) and returns
`true`. An unbound combo — ⌘J, or New Space…'s ⇧⌘N — reports **not** consumed
and falls through to the menu untouched.

So: adding a ⌘ shortcut to the menu bar is only half the work. Check whether
libghostty binds it, and if it does, claim its action in `LayoutActionHandler`
as well, or the shortcut is dead everywhere except a screen with no surface on
it (the empty state).
`Tests/CasperGhosttyTests/GhosttyCommandNRoutingTests.swift` pins both sides
on a real surface: ⌘N consumed as `.newWindow`, ⇧⌘N not consumed. Swapping a
keycode there (⇧⌘D, say) is the quickest way to check whether a combo is
bound.
