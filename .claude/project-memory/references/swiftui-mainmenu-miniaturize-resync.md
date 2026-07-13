---
name: "SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe"
description: "SwiftUI re-syncs NSApp.mainMenu on scene-lifecycle events, so Casper's menu bar is defined entirely in .commands; empty Format/Help stubs are stripped on BOTH applicationWillUpdate and applicationDidUpdate to beat SwiftUI's multi-pass resync flicker"
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
"Help" title on the bar (confirmed via Apple Developer Forums; there is no clean
official fix). Casper strips those empty stubs in a shared
`stripEmptyTopLevelMenus()` helper called from **both**
`AppDelegate.applicationWillUpdate(_:)` **and** `applicationDidUpdate(_:)`, which
removes every empty top-level menu (`item.submenu?.numberOfItems == 0`).

Why both, not `didUpdate` alone: SwiftUI resyncs the menu in **multiple passes**
spanning ~250 ms (verified by logging the menu-bar composition each `didUpdate`),
re-inserting the empty Format/Help stubs on each pass until it settles. A single
`didUpdate` strip loses that race — SwiftUI re-adds the stub between callbacks and
the bar renders the empty title in the gap = the intermittent menu-bar flicker.
Stripping on both the will- and did-update passes minimizes the window in which a
stub is visible (measured: at startup, Format/Help exposure at the `didUpdate`
probe dropped from 2 transitions to 0, and the resync settled in 2 passes instead
of 3). `willUpdate` **alone** is still wrong (SwiftUI re-inserts *during* the
update, after `willUpdate`, so the stub survives) — the fix is the pair.

Confirmed facts (from instrumented runs): the Help menu is `NSApp.helpMenu` and
the Window menu is `NSApp.windowsMenu` (locale-independent handles); our
App/File/Edit/View/Window are always populated, so empty-submenu detection targets
*exactly* Format+Help without matching titles (locale-independent — important, the
system localizes "Help" to e.g. "Aide"). The flicker is triggered by
window/app-lifecycle resyncs (app-switch, miniaturize, fullscreen), **not** by
`CasperCommands.body` re-evaluation — a busy terminal re-evaluates the Commands
body many times/sec (it reads the whole `spaces` graph via
`workspace(id:)`/`targetSpaceForNewWorkspace()`) yet never re-inserts the stubs
(0 strips), because an unchanged menu structure triggers no native menu mutation.
That over-coupling of the Commands body to `spaces` is wasted work but is *not*
the flicker cause; decoupling it is a separate efficiency improvement.

This strip is safe — it never touches File/Edit/View/App/Window (always
populated), and cannot loop (once stripped, the next pass finds nothing to
remove).
