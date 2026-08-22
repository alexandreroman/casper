---
name: "Command key-ups need a local NSEvent monitor"
description: "AppKit withholds keyUp for command combos, so the press performKeyEquivalent sends libghostty is matched by a release from a local monitor"
type: reference
---

# Command key-ups need a local NSEvent monitor

AppKit routes a ⌘ combo to `performKeyEquivalent(with:)`, never to `keyDown`,
and it **never delivers the matching `keyUp:`** through the responder chain
either. `GhosttySurfaceView.performKeyEquivalent` sends libghostty a
`GHOSTTY_ACTION_PRESS`, so without a compensating path every ⌘ combo leaves
libghostty's press/release bookkeeping short one release — the same imbalance
`keyDown` takes care to avoid when `interpretKeyEvents` commits text in
several chunks.

The answer is upstream Ghostty's ([[ghostty-is-the-reference]]): a
process-local event monitor. `installCommandKeyUpMonitor()` registers
`NSEvent.addLocalMonitorForEvents(matching: .keyUp)` for the view's whole
lifetime (removed in `deinit`), forwards an event to `keyUp(with:)` — which
sends `GHOSTTY_ACTION_RELEASE` — when it carries `.command` **and** this view
is the window's first responder, and consumes it; everything else is returned
unchanged so its real target still sees it. Upstream does exactly this in
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` (v1.3.1,
`localEventKeyUp`), commenting "We need keyUp because command+key events don't
trigger keyUp" and "Command keyUp events are never sent to the normal
responder chain". Upstream's own `performKeyEquivalent` sends only a press; the
release comes from the monitor, riding the real physical key-up rather than
being synthesized immediately.

Two constraints on the Swift side: `NSEvent` is not `Sendable`, so the
monitor's handler must return a `Bool` out of its `MainActor.assumeIsolated`
block and choose the event outside it, and the monitor token is
`nonisolated(unsafe)` so `deinit` can drop it without a main-actor hop (see
[[isolated-deinit-ci-sigabrt]]). Related: [[ghostty-key-encoding]].
