---
name: "SwiftUI/AppKit main-menu resync on window miniaturize"
description: "NSApp.mainMenu.items gets mutated in place during window miniaturize; no public API prevents it, so the custom menu must be reasserted afterward"
type: reference
---

# SwiftUI/AppKit main-menu resync on window miniaturize

`CasperApp` is a SwiftUI `App` (`WindowGroup`, no proper `.commands`-driven menu
of its own) whose `AppDelegate.applicationDidFinishLaunching` builds and installs
the entire menu bar imperatively via AppKit (`NSApp.mainMenu = buildMainMenu()` +
inserting Casper's own File/View menus). When the app's window is minimized,
something internal to AppKit/SwiftUI's main-menu management mutates
`NSApp.mainMenu.items` **in place** — same `NSMenu` object identity, contents
replaced with a generic default menu (drops File/Edit, injects a stray Help
menu, sometimes a Format menu depending on responder state).

Confirmed via live instrumentation: logging `ObjectIdentifier(NSApp.mainMenu)`
and `NSApp.mainMenu?.items.map(\.title)` around `NSWindow.willMiniaturizeNotification`
/ `didMiniaturizeNotification` showed the identical object identity throughout,
with the item titles already corrupted by the time `didMiniaturizeNotification`
fires (the mutation happens during the miniaturize genie-animation window).
Adding a SwiftUI `.commands { CommandGroup(replacing: ...) {} }` modifier to
neutralize SwiftUI's default command groups had **no effect** on this — the
resync is not driven by the public Commands API, and there is no public API to
suppress it.

**Why:** this is closed-source SwiftUI/AppKit internal behavior; whack-a-mole
neutralizing more `CommandGroup` placements does not stop it.

**How to apply:** any window-lifecycle-sensitive AppKit customization on
`NSApp.mainMenu` (or, likely, other AppKit chrome SwiftUI also manages) must be
**reasserted after the fact** rather than assumed to survive scene-lifecycle
events. `AppDelegate` now reinstalls the custom menu via
`NSWindow.didMiniaturizeNotification` and `didDeminiaturizeNotification`
observers calling a shared `installCustomMainMenu()` helper — this pattern
(reassert-after-corrupting-event, confirmed via object-identity diagnostic
logging) is the template to reach for if similar AppKit-chrome corruption shows
up on other window-lifecycle transitions (fullscreen toggle, tab merging, etc.).
