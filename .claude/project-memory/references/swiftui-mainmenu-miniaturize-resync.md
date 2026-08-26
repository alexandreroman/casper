---
name: "SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe"
description: "Casper's menu bar is SwiftUI .commands; the .commands body must not observe volatile state, or SwiftUI re-asserts the whole menu"
type: reference
---

# SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe

Casper's menu bar is defined entirely in SwiftUI `.commands` (`CasperCommands`
in `Sources/CasperUI/MenuCommands.swift`, wired via `CasperApp.body`'s
`.commands { CasperCommands(model: model) }`). File ← `.newItem`, Edit ←
`.pasteboard`, View ← `.sidebar`; App/Window use SwiftUI defaults. The File
slot's menu is titled **"Space"** on the bar — see "Renaming the File menu"
below; every other placement's visible title is the standard one. Edit
Copy/Paste/Select All carry no target —
`NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)` routes
through the responder chain to the focused `GhosttySurfaceView` (and to text
fields), so they stay always-enabled by design.

Menu enable-state does NOT read raw `@Observable` state directly (that flickers
— see below). It reads **edge-triggered stored flags** on `AppModel`
(`menuHasSelectedWorkspace`, `menuCanCreateWorkspace`,
`menuCanDeleteSelectedWorkspace`, `menuCanCloseSelectedWorkspace`) bound via
`.disabled(...)`. `refreshMenuFlags()` recomputes each flag from the underlying
computed props and writes it back **only when it flips** (the `!=` guard is
essential — an unconditional write to an `@Observable` var notifies observers
even when unchanged). It is driven by `didSet` on `spaces` and
`selectedWorkspaceID` **only**. `focusedSurfaceID` deliberately has **no**
`didSet`: the menu must not react to focus changes. The View menu's **Split**
items are **always enabled** (no focus-dependent `.disabled`); `applyNewSplit`
gates itself with `focusedSurfaceIsTerminal()`. Covered by
`Tests/CasperUITests/MenuStateTests.swift`.

**Why:** building the whole bar imperatively in AppKit
(`NSApp.mainMenu = buildMainMenu()` + inserting File/View) fails, because
SwiftUI's `WindowGroup` re-synchronises `NSApp.mainMenu` on scene-lifecycle
events (miniaturize, app-switch, key-window change, fullscreen, …), mutating
`NSApp.mainMenu.items` **in place** (same `NSMenu` object identity) and wiping
the custom File/Edit/View while re-injecting SwiftUI's Format/Help — the
intermittent "File/Edit disappeared" bug. This is closed-source internal
behaviour with no public API to suppress; reasserting a custom menu only on
specific notifications (miniaturize/deminiaturize observers, say) is
whack-a-mole that misses every other trigger. Letting SwiftUI **own** the menu
makes the resync harmless: SwiftUI re-applies the same `.commands` on every
resync, so the important menus survive it.

**How to apply:** never mutate `NSApp.mainMenu` imperatively to define menus in
this app — express menus in `.commands`. One genuine SwiftUI limitation remains:
`.commands` cannot remove an entire default top-level menu — an emptied
`CommandGroup(replacing: .textFormatting)` / `.help` leaves the empty "Format" /
"Help" title on the bar (confirmed via Apple Developer Forums; there is no clean
official fix). Casper strips those empty stubs in a shared
`stripEmptyTopLevelMenus()` helper called from **both**
`AppDelegate.applicationWillUpdate(_:)` **and** `applicationDidUpdate(_:)`,
which removes every empty top-level menu (`item.submenu?.numberOfItems == 0`).

Why both, not `didUpdate` alone: SwiftUI resyncs the menu in **multiple passes**
spanning ~250 ms (verified by logging the menu-bar composition each
`didUpdate`), re-inserting the empty Format/Help stubs on each pass until it
settles. A single `didUpdate` strip loses that race — SwiftUI re-adds the stub
between callbacks and the bar renders the empty title in the gap = the
intermittent menu-bar flicker. Stripping on both the will- and did-update passes
minimizes the window in which a stub is visible (measured: at startup,
Format/Help exposure at the `didUpdate` probe dropped from 2 transitions to 0,
and the resync settled in 2 passes instead of 3). `willUpdate` **alone** is
still wrong (SwiftUI re-inserts *during* the update, after `willUpdate`, so the
stub survives) — the fix is the pair.

The stubs are safe to detect by emptiness: Help is `NSApp.helpMenu`, Window is
`NSApp.windowsMenu` (locale-independent handles), and our
App/File/Edit/View/Window are always populated, so empty-submenu detection
targets *exactly* Format+Help without matching titles (important — the system
localizes "Help" to e.g. "Aide"). The strip is safe (never touches the
always-populated menus) and cannot loop.

**Services is stripped in AppKit too, from the App menu's `NSMenuDelegate`
rather than from the update hooks.** `AppMenuDelegateProxy` and
`installAppMenuDelegateProxy` in `Sources/CasperUI/AppDelegate.swift` carry the
mechanism, the proxy's forwarding invariants, and the timestamped measurement
that rules the update hooks out as the only strip point.

## Renaming the File menu

The menu occupying the standard File slot reads **"Space"** on the bar, applied
by `AppDelegate.renameFileMenu(in:)` from `resyncMainMenu()`. SwiftUI cannot do
it: `.commands` positions a group into a standard menu
(`CommandGroup(replacing: .newItem)`) but exposes no title for it, and the only
titled construct — an additive `CommandMenu` — lands after Window instead of in
the File slot. Like the strips, the rename runs on **every** update pass, since
each resync re-asserts `NSApp.mainMenu` with the standard localized title.

Both `NSMenuItem.title` and `submenu.title` are set (AppKit draws the
*submenu's* title in the bar), and only when one of them differs. The menu is
matched **structurally**, never by title (macOS localizes "File", and after the
first pass the title is Casper's own): the marker is
`CasperCommands.addFolderTitle` — `"Add Folder…"`, an unlocalized Casper string
— compared against the submenu's **first** item, which holds because
`.newItem` is the only group Casper leaves populated there. That string is
load-bearing for the rename; the shared `static let` is what keeps the two
sites from drifting. The rename cannot disturb `stripEmptyTopLevelMenus(in:)`,
which keys on an empty submenu.

## The resync pass runs unconditionally — do not add an early-out cache

`resyncMainMenu()` resolves `NSApp.mainMenu` once and passes it down;
`stripEmptyTopLevelMenus(in:)`, `stripServicesItems(fromAppMenu:)` and
`normalizeSeparators(in:)` all walk indices backwards through
`item(at:)`/`numberOfItems` rather than touching `.items`, which bridges a whole
ObjC array into a fresh Swift array on every access. Both update hooks fire
after essentially every event AppKit processes — mouse-moved included — so that
bridging, not the menu work itself, was the cost worth removing.

Skipping the pass when `NSApp.mainMenu`'s identity **and** `numberOfItems` are
unchanged is the obvious next optimization, and it is **rejected**:

- A matching main-menu identity and count does not imply the App menu is
  unchanged. A Services re-injection alters only the *App submenu's* item count,
  which the main menu's own count cannot see — so the early-out would skip
  precisely the idle re-injection this whole mechanism exists to catch.
- It cannot tell a SwiftUI rebuild that happens to land on the same item count
  from no rebuild at all. Winning that race is why the will/did double hook
  exists in the first place.

With the array bridging gone, one pass is a handful of ObjC message sends, so
the cache would buy very little for that risk.

The proxy is confirmed working against a human click, and the same logs settle
the mechanism: on the first opening, `menuNeedsUpdate:` logged
`before=[About | --- | Services | --- | Hide | …]` /
`after=[About | --- | Hide | …]`, so Services was **already in the menu** when
the callback fired — put there by an earlier idle resync, not by SwiftUI
re-injecting inside `menuNeedsUpdate:` (the `willOpen` pass that follows already
sees a clean menu). A later opening logged a `before=` with no Services at all,
i.e. re-injection is intermittent, not per-open. Verifying this needs a real
click: the debug channel exposes only terminal surfaces, and assistive access
(osascript/System Events/CGEvent) plus screen capture are both denied to agents
here, so no menu-bar state can be observed or driven from outside the app —
in-app `.debug` logging is the only instrument, and a human has to open the
menu.

`stripServicesItems(fromAppMenu:)` carries the detection rule and why
`NSApp.servicesMenu` is not a usable gate for it.

Two related observations from the same instrumentation, useful for the next
menu-bar investigation: (1) `applicationWillUpdate`/`DidUpdate` fire only while
the app processes events — an idle or background instance runs **zero** strip
passes even though SwiftUI keeps mutating state, so any re-injection in that
window survives until the next event — this is what makes the update hooks alone
insufficient for Services; (2) menu-open time is not a *re-injection* point
(neither `NSMenu.update()` nor `NSMenuDidBeginTracking` was observed putting
Services back), but it **is** the correct *strip* point: by then the item is
already there from an earlier idle resync, and `menuNeedsUpdate:` is the last
moment at which removing it is still invisible to the user. `.debug` logs are
not persisted to the log store — read them with `log stream --level debug`
started **before** launching the app, not with `log show --debug` afterwards.

**The complete flicker mechanism (root cause).** The empty Format/Help stubs are
created by CasperCommands' **own** `CommandGroup(replacing: .textFormatting) {}`
/ `.help {}` (not just SwiftUI defaults — confirmed: `.commandsRemoved()` did
NOT remove them; deleting those two lines did). SwiftUI re-asserts the
**entire** native menu — recreating those empty stubs — whenever **either** (a)
an AppKit scene-lifecycle resync fires (app-switch, miniaturize, fullscreen,
startup), OR (b) the `.commands` body's observed output **changes** (an
enable-state flips). The will+did strip mitigates (a). Case (b) is why the menu
body must not observe volatile state: a body that reads `focusedSurfaceID`
re-asserts the menu on **every** focus switch between panes (each recreates the
stubs = flicker), even though the resulting enable-state is identical. Reading a
*stable* edge-triggered flag instead means focus switches that don't flip an
enable-state trigger no re-assert and no flicker. (A busy terminal that only
churns `spaces` — via `workspace(id:)`/`targetSpaceForNewWorkspace()` —
re-evaluates the body but with *unchanged* output, so it already causes no
re-assert; the flags also make that churn free.)

**Why `.commandsRemoved()` is not the fix** (evaluated and rejected): it removes
*all* default commands including the native App menu (About/Settings/Services/
Hide/Quit) and Window menu (Minimize/Zoom/window-list). There is no public API
to re-add a single default group, and `.systemServices`/`.windowList` are
AppKit- populated (`NSApp.servicesMenu`/`NSApp.windowsMenu`) — not reproducible
in pure SwiftUI without the imperative-menu approach this project rejects. So
Format/Help must be emptied-and-stripped, not removed.

**The Split UX trade-off** (deliberate): greying a menu item requires SwiftUI to
observe the enable-state, and any change re-asserts the menu → recreates the
stubs → one flicker. So on a focus change that legitimately flips Split's
enabled-state (terminal↔browser), greying and zero-flash are mutually exclusive
under SwiftUI. Casper takes **zero-flash**: Split stays always-enabled and
`applyNewSplit` no-ops when `focusedSurfaceIsTerminal()` is false.
`focusedSurfaceID` does not change when focus moves to the browser's **address
bar** (a non-surface first responder), so a `focusedSurfaceID`-based
*enable-state* could never be fully generic anyway — another reason the
action-gate approach is cleaner.
