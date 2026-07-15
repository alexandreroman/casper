---
name: "SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe"
description: "Casper's menu bar is SwiftUI .commands; empty Format/Help stubs stripped on will+didUpdate; the .commands body must NOT observe volatile state (focus/spaces) or SwiftUI re-asserts the whole menu and flickers the stubs — so enable-states are edge-triggered flags and Split is always-enabled"
type: reference
---

# SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe

Casper's menu bar is defined entirely in SwiftUI `.commands` (`CasperCommands` in
`Sources/CasperUI/MenuCommands.swift`, wired via `CasperApp.body`'s
`.commands { CasperCommands(model: model) }`). File ← `.newItem`, Edit ←
`.pasteboard`, View ← `.sidebar`; App/Window use SwiftUI defaults. Edit
Copy/Paste/Select All carry no target — `NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)`
routes through the responder chain to the focused `GhosttySurfaceView` (and to
text fields), so they stay always-enabled by design.

Menu enable-state does NOT read raw `@Observable` state directly (that flickers —
see below). It reads **edge-triggered stored flags** on `AppModel`
(`menuHasSelectedWorkspace`, `menuCanCreateWorkspace`,
`menuCanDeleteSelectedWorkspace`, `menuCanCloseSelectedWorkspace`) bound via
`.disabled(...)`. `refreshMenuFlags()` recomputes each flag from the underlying
computed props and writes it back **only when it flips** (the `!=` guard is
essential — an unconditional write to an `@Observable` var notifies observers even
when unchanged). It is driven by `didSet` on `spaces` and `selectedWorkspaceID`
**only**. `focusedSurfaceID` deliberately has **no** `didSet`: the menu must not
react to focus changes. The View menu's **Split** items are **always enabled** (no
focus-dependent `.disabled`); `applyNewSplit` gates itself with
`focusedSurfaceIsTerminal()`. Covered by `Tests/CasperUITests/MenuStateTests.swift`.

**Why:** building the whole bar imperatively in AppKit
(`NSApp.mainMenu = buildMainMenu()` + inserting File/View) fails, because SwiftUI's
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

The stubs are safe to detect by emptiness: Help is `NSApp.helpMenu`, Window is
`NSApp.windowsMenu` (locale-independent handles), and our App/File/Edit/View/Window
are always populated, so empty-submenu detection targets *exactly* Format+Help
without matching titles (important — the system localizes "Help" to e.g. "Aide").
The strip is safe (never touches the always-populated menus) and cannot loop.

**The complete flicker mechanism (root cause).** The empty Format/Help stubs are
created by CasperCommands' **own** `CommandGroup(replacing: .textFormatting) {}` /
`.help {}` (not just SwiftUI defaults — confirmed: `.commandsRemoved()` did NOT
remove them; deleting those two lines did). SwiftUI re-asserts the **entire**
native menu — recreating those empty stubs — whenever **either** (a) an AppKit
scene-lifecycle resync fires (app-switch, miniaturize, fullscreen, startup), OR
(b) the `.commands` body's observed output **changes** (an enable-state flips). The
will+did strip mitigates (a). Case (b) is why the menu body must not observe
volatile state: a body that reads `focusedSurfaceID` re-asserts the menu on
**every** focus switch between panes (each recreates the stubs = flicker), even
though the resulting enable-state is identical. Reading a *stable* edge-triggered
flag instead means focus switches that don't flip an enable-state trigger no
re-assert and no flicker. (A busy terminal that only churns `spaces` — via
`workspace(id:)`/`targetSpaceForNewWorkspace()` — re-evaluates the body but with
*unchanged* output, so it already causes no re-assert; the flags also make that
churn free.)

**Why `.commandsRemoved()` is not the fix** (evaluated and rejected): it removes
*all* default commands including the native App menu (About/Settings/Services/
Hide/Quit) and Window menu (Minimize/Zoom/window-list). There is no public API to
re-add a single default group, and `.systemServices`/`.windowList` are AppKit-
populated (`NSApp.servicesMenu`/`NSApp.windowsMenu`) — not reproducible in pure
SwiftUI without the imperative-menu approach this project abandoned. So Format/Help
must be emptied-and-stripped, not removed.

**The Split UX trade-off** (deliberate): greying a menu item requires SwiftUI to
observe the enable-state, and any change re-asserts the menu → recreates the stubs
→ one flicker. So on a focus change that legitimately flips Split's enabled-state
(terminal↔browser), greying and zero-flash are mutually exclusive under SwiftUI.
The user chose **zero-flash**: Split stays always-enabled and `applyNewSplit`
no-ops when `focusedSurfaceIsTerminal()` is false. `focusedSurfaceID` does not
change when focus moves to the browser's **address bar** (a non-surface first
responder), so a `focusedSurfaceID`-based *enable-state* could never be fully
generic anyway — another reason the action-gate approach is cleaner.
