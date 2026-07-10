---
name: "SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe"
description: "SwiftUI re-syncs NSApp.mainMenu on scene-lifecycle events, so Casper's menu bar is defined entirely in .commands; empty top-level stubs are stripped in applicationDidUpdate"
type: reference
---

# SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe

Casper's menu bar is defined entirely in SwiftUI `.commands` (`CasperCommands` in
`Sources/CasperUI/MenuCommands.swift`, wired via `CasperApp.body`'s
`.commands { CasperCommands(model: model) }`). File ← `.newItem`, Edit ←
`.pasteboard`, View ← `.sidebar`; App/Window use SwiftUI defaults. Edit
Copy/Paste/Select All carry no target — `NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)`
routes through the responder chain to the focused `GhosttySurfaceView` (and to
text fields), so they stay always-enabled by design. Menu enable/disable lives in
testable `@Observable` computed props on `AppModel` (`canCreateWorkspace`,
`canCloseSelectedWorkspace`, `canDeleteSelectedWorkspace`, `canSplitFocusedSurface`,
`hasSelectedWorkspace`), bound via `.disabled(...)` and covered by
`Tests/CasperUITests/MenuStateTests.swift`.

**Why:** an earlier design built the whole bar imperatively in AppKit
(`NSApp.mainMenu = buildMainMenu()` + inserting File/View), but SwiftUI's
`WindowGroup` re-synchronises `NSApp.mainMenu` on scene-lifecycle events
(miniaturize, app-switch, key-window change, fullscreen, …), mutating
`NSApp.mainMenu.items` **in place** (same `NSMenu` object identity) and wiping
the custom File/Edit/View while re-injecting SwiftUI's Format/Help — the
intermittent "File/Edit disappeared" bug. This is closed-source internal
behaviour with no public API to suppress; reasserting the custom menu only on
specific notifications (the old miniaturize/deminiaturize observers) was
whack-a-mole that missed every other trigger. Letting SwiftUI **own** the menu
makes the resync harmless: SwiftUI re-applies the same `.commands` on every
resync, so the important menus can no longer vanish.

**How to apply:** never mutate `NSApp.mainMenu` imperatively to define menus in
this app — express menus in `.commands`. One genuine SwiftUI limitation remains:
`.commands` cannot remove an entire default top-level menu — an emptied
`CommandGroup(replacing: .textFormatting)` / `.help` leaves the empty "Format" /
"Help" title on the bar (confirmed via Apple Developer Forums). Casper strips
those in `AppDelegate.applicationDidUpdate(_:)`, which removes every empty
top-level menu (`item.submenu?.numberOfItems == 0`). It must be `didUpdate`, not
`willUpdate`: SwiftUI re-inserts the empty Format/Help stubs *during* the update,
so stripping *before* the update (`willUpdate`) leaves the re-inserted stubs
visible until a later cycle — the intermittent "Format/Help swap in" bug. Running
*after* the rebuild strips them on the same cycle, before the bar is displayed.
This is safe — it never touches File/Edit/View/App/Window (always populated), and
cannot loop (once stripped, the next `didUpdate` finds nothing to remove). If you must own
other window-lifecycle-sensitive AppKit chrome that SwiftUI also manages, prefer
the SwiftUI-declared route + an `applicationWillUpdate` reconcile over
reasserting on individual notifications.
