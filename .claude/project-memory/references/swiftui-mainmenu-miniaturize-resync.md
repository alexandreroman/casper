---
name: "SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe"
description: "Casper's menu bar is SwiftUI .commands; the .commands body must not observe volatile state, or SwiftUI re-asserts the whole menu"
type: reference
---

# SwiftUI owns the main menu; AppKit resync makes imperative menus unsafe

Casper's menu bar is defined entirely in SwiftUI `.commands` (`CasperCommands`
in `Sources/CasperUI/MenuCommands.swift`, wired via `CasperApp.body`'s
`.commands { CasperCommands(model: model) }`). File ← `.newItem`, Edit ←
`.pasteboard`, View ← `.sidebar`; App/Window use SwiftUI defaults. Edit
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

**Services is removed too, and also in AppKit — but from the App menu's
`NSMenuDelegate`, not from the update hooks.** Casper does not expose the App
menu's Services submenu. There is no SwiftUI `CommandGroup` for it — AppKit
fills it via `NSApp.servicesMenu` — so the removal has to happen in AppKit, and
SwiftUI re-injects it on every resync (observed: a full re-assertion ~3.4 s
after launch put `Services` back), so a one-shot removal at launch never holds.

**Stripping only from `applicationWillUpdate`/`DidUpdate` does not work, and
cannot.** Both hooks run **after** AppKit has already drawn the menu, so on the
pass that matters they lose the race by construction. The chronology that proved
it, on one long-running instance (each timestamp is a *successful* removal,
logged by the strip itself): `12:47:01` at launch, then `13:55:42`, `13:55:56`,
`13:56:06` — one per menu opening — while a screenshot taken during those
openings shows Services **present and expanded**. The item was removed every
single time, always too late to be invisible. Combined with observation (1)
below (an idle app runs zero strip passes), the failure mode is: SwiftUI
re-injects Services while the app is idle, nothing strips it, the user clicks,
AppKit draws the menu *with* Services, and only then does `willUpdate`/
`DidUpdate` fire and remove it.

**The fix is `NSMenuDelegate.menuNeedsUpdate(_:)`** — the callback AppKit
invokes immediately *before* displaying a menu, and the documented point for
mutating menu contents. The App menu already has a delegate (SwiftUI's
`AppKitMainMenuItem`, confirmed by logging), so Casper does not replace it: an
`AppMenuDelegateProxy` (private to `AppDelegate.swift`) **wraps** it. It calls
`original?.menuNeedsUpdate?(menu)` **first**, then strips — that order is
required, since the wrapped delegate is free to re-assert the menu's contents in
its own callback. Everything the proxy does not implement reaches SwiftUI
through ObjC forwarding: `forwardingTarget(for:)` returns the original and
`responds(to:)` is `super.responds(to:) || original?.responds(to:) == true` —
the two must agree, or AppKit's optional-method probes ask the wrong object and
the menu bar breaks. `menuWillOpen(_:)` is wrapped the same way, as a
belt-and-braces second pre-display pass. The original is held **weakly**
(SwiftUI owns it) and the proxy is retained by `AppDelegate`, because
`NSMenu.delegate` is weak. `installAppMenuDelegateProxy()` runs on every
will/did-update pass and re-wraps whenever the current delegate is not our proxy
(SwiftUI swapped it once ~150 ms after launch, then left it alone); a proxy is
never wrapped in a proxy — the delegate it was already forwarding to is reused.
The identity guard must be
`if let installed = proxy, menu.delegate === installed` and **not**
`menu.delegate !== proxy`: `nil === nil` is true, which would skip the first
install on a delegate-less menu.

`stripServicesItems(fromAppMenu:)` also runs from
`applicationWillUpdate`/`DidUpdate`, before `stripEmptyTopLevelMenus()` (so the
empty-stub pass sees the final menu). That call is a safety net for
re-injections that happen with no menu open — not the fix.

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

**`NSApp.servicesMenu` is NOT a usable handle — never gate on it.** The obvious
implementation (match the item by submenu identity,
`$0.submenu === NSApp.servicesMenu`, then nil the property and let that
early-return later passes) is wrong. Logging the property on every
will/didUpdate pass showed it is **not** a mirror of the item's presence: after
`NSApp.servicesMenu = nil` at pass 1, pass 2 — 8 ms later — already read it back
as **non-nil while no submenu-bearing item was in the App menu at all**. Both
AppKit and SwiftUI write to it, independently of what is in the menu. Using it
as the entry condition therefore makes the strip effectively one-shot: any
resync that re-inserts the Services item while the property happens to be nil is
never cleaned up, and the item stays visible forever.

**What the strip matches instead:** in the App menu, Services is the **only**
item carrying a submenu — the live dump is
`About | --- | Hide | Hide Others | Show All | --- | Quit`, all plain items, so
`item.submenu != nil` identifies Services alone. That criterion is
locale-independent (macOS localizes "Services"), identity-independent,
idempotent, re-triggerable on every pass, and confined to the App menu.
`NSApp.servicesMenu = nil` is still done **after** the removal so AppKit stops
feeding the orphaned submenu, but purely as an effect — never as a precondition.
The strip also collapses the orphaned separator pair AppKit leaves behind
(`normalizeSeparators(in:)`).

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
