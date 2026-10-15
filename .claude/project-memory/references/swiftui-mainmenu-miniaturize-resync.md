---
name: "SwiftUI owns the main menu"
description: "Casper's menu bar is SwiftUI .commands; the .commands body must not observe volatile state, or SwiftUI re-asserts the whole menu"
type: reference
---

# SwiftUI owns the main menu

Casper's menu bar is defined entirely in SwiftUI `.commands` (`CasperCommands`
in `Sources/CasperUI/MenuCommands.swift`, wired via `CasperApp.body`'s
`.commands { CasperCommands(model: model) }`). The menus, their placements and
every enable-state flag are inventoried in `.superpowers/themes/app-ui.md`
§ Design → "Menu bar". The bar reads App, Space, Workspace, Edit, View,
Window, and two of those placements are AppKit fixups `.commands` cannot
express: the standard File slot is retitled "Space", and the Workspace
`CommandMenu`, which SwiftUI always lands between View and Window, is moved
right after Space (see "Renaming the File menu" and "Moving the Workspace
menu" below).

The `CasperCommands` body observes **no volatile state** — no selection, no
focus, no per-workspace data. SwiftUI re-asserts the whole native menu whenever
that body's observed output changes, and each re-assert flickers the bar (the
mechanism is below). Enable-state and checkmarks therefore read
**edge-triggered stored flags** on `AppModel` (`menu…`), and actions resolve
the selected workspace when they fire. Each flag is written back **only when it
flips**: the `!=` guard is essential, since an unconditional write to an
`@Observable` var notifies observers even when the value is unchanged.
`focusedSurfaceID` has **no** `didSet`, so a focus change never touches a flag;
the View menu's Split items are always enabled and `applyNewSplit` gates itself
on `locateFocusedTerminal()`. Covered by
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
official fix). Casper strips those empty stubs in
`stripEmptyTopLevelMenus(in:)`, which removes every empty top-level menu
(`item.submenu?.numberOfItems == 0`); `resyncMainMenu()` runs it, and **both**
`AppDelegate.applicationWillUpdate(_:)` **and** `applicationDidUpdate(_:)` call
`resyncMainMenu()`.

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

**An empty `CommandMenu` is not a stub.** SwiftUI fills a `CommandMenu`'s
submenu lazily, through the submenu's delegate (`menuNeedsUpdate(_:)`) when it
is opened, and a re-assert of the main menu hands it back with zero items. An
emptiness-only strip removes it then, and SwiftUI never re-adds it — the menu
is simply gone from the bar. Nothing structural tells it apart from the
Format/Help stubs (same emptiness, same SwiftUI delegate class,
`AppKitMainMenuItem`), so `AppDelegate.stripEmptyTopLevelMenus(in:)` skips it
by `CasperCommands.workspaceMenuTitle`. Any further `CommandMenu` needs the same
exemption.

**Services is stripped in AppKit too, from the App menu's `NSMenuDelegate`
rather than from the update hooks.** `AppMenuDelegateProxy` and
`installAppMenuDelegateProxy` in `Sources/CasperUI/AppDelegate.swift` carry the
mechanism, the proxy's forwarding invariants, and the timestamped measurement
that rules the update hooks out as the only strip point.

## Renaming the File menu

The menu occupying the standard File slot reads **"Space"** on the bar, applied
by `AppDelegate.renameFileMenu(in:)` from `resyncMainMenu()`. SwiftUI cannot do
it: `.commands` positions a group into a standard menu (`CommandGroup(replacing:
.newItem)`) but exposes no title for it, and the only titled construct — an
additive `CommandMenu` — lands between View and Window instead of in the File
slot. Like the strips, the rename runs on **every** update pass, since each
resync re-asserts `NSApp.mainMenu` with the standard localized title.

Both `NSMenuItem.title` and `submenu.title` are set (AppKit draws the
*submenu's* title in the bar), and only when one of them differs. The menu is
matched **structurally**, never by title (macOS localizes "File", and after the
first pass the title is Casper's own): the marker is
`CasperCommands.newSpaceTitle` — `"New Space…"`, an unlocalized Casper string
— compared against the submenu's **first** item, which holds because
`.newItem` is the only group Casper leaves populated there. That string is
load-bearing for the rename; the shared `static let` is what keeps the two
sites from drifting. The rename cannot disturb `stripEmptyTopLevelMenus(in:)`,
which keys on an empty submenu. The lookup (`AppDelegate.spaceMenuIndex(in:)`)
checks a submenu is non-empty before asking for its first item:
`NSMenu.item(at:)` raises on an out-of-range index rather than returning nil,
and SwiftUI's empty Format/Help stubs can be on the bar mid-resync.

## Moving the Workspace menu

`AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in:)` moves the Workspace
top-level `NSMenuItem` to the index right after the Space menu, from
`resyncMainMenu()`, on every update pass. It finds the item by
`CasperCommands.workspaceMenuTitle` (the `CommandMenu`'s own unlocalized title)
and moves nothing when the order is already right, so a settled bar is never
mutated. Covered headlessly by
`Tests/CasperUITests/MainMenuPlacementTests.swift`.

Every SwiftUI re-assert of the menu puts Workspace back between View and Window
— observed after a `Commands` body output change, miniaturize, hide/unhide and a
key-equivalent dispatch — and the next update pass moves it again, the same race
the Format/Help strips run. The move does not fight SwiftUI otherwise (checked
in a throwaway SwiftUI app): SwiftUI repositions the same item rather than
duplicating it, and the moved submenu keeps its items, actions, enable-state and
checkmarks; opening the moved menu still fills it, since the submenu travels
with its delegate. Because of the lazy fill (see above), a probe that reads a
`CommandMenu` submenu without opening it or calling its delegate sees it empty,
and a probe that omits the strip cannot reproduce what the strip does to it.

## The resync pass runs unconditionally — do not add an early-out cache

`resyncMainMenu()` resolves `NSApp.mainMenu` once and passes it down;
`stripEmptyTopLevelMenus(in:)`, `stripServicesItems(fromAppMenu:)` and
`normalizeSeparators(in:)` all walk indices backwards through
`item(at:)`/`numberOfItems` rather than touching `.items`, which bridges a whole
ObjC array into a fresh Swift array on every access. Both update hooks fire
after essentially every event AppKit processes — mouse-moved included — so that
bridging, not the menu work itself, is the cost that matters.

Skipping the pass when `NSApp.mainMenu`'s identity **and** `numberOfItems` are
unchanged is the obvious next optimization, and it is **rejected**:

- A matching main-menu identity and count does not imply the App menu is
  unchanged. A Services re-injection alters only the *App submenu's* item count,
  which the main menu's own count cannot see — so the early-out would skip
  precisely the idle re-injection this whole mechanism exists to catch.
- It cannot tell a SwiftUI rebuild that happens to land on the same item count
  from no rebuild at all. Winning that race is why the will/did double hook
  exists in the first place.

Without array bridging, one pass is a handful of ObjC message sends, so the
cache would buy very little for that risk.

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
`applyNewSplit` no-ops when `locateFocusedTerminal()` returns nil.
`focusedSurfaceID` does not change when focus moves to the browser's **address
bar** (a non-surface first responder), so a `focusedSurfaceID`-based
*enable-state* could never be fully generic anyway — another reason the
action-gate approach is cleaner.
