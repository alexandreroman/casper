---
name: "MainRunLoop is the shared modal-proof main-thread hop"
description: "CasperUI's MainRunLoop.perform reaches the main thread even while a modal panel is up; DispatchQueue.main.async does not"
type: reference
---

# MainRunLoop is the shared modal-proof main-thread hop

`Sources/CasperUI/MainRunLoop.swift` is CasperUI's one route for "run this on
the main thread, on a later turn of its run loop":

```swift
MainRunLoop.perform { /* runs on the main thread, off the current turn */ }
```

`perform` is `nonisolated` and takes a `@Sendable` block, so it is callable
from any thread — an FSEvents queue as readily as the main actor. It wraps
`CFRunLoopPerformBlock` on `CFRunLoopGetMain()` with a modes array covering
`kCFRunLoopCommonModes`, `NSModalPanelRunLoopMode` and
`NSEventTrackingRunLoopMode`, then `CFRunLoopWakeUp` so an idle loop asleep in
`mach_msg` does not sit on the block.

**`DispatchQueue.main.async` is not a substitute.** A nested modal run loop —
`NSAlert`/`NSOpenPanel` `runModal`, a Sparkle update check, menu or drag
tracking — starves the main dispatch queue for its whole duration, while it
does drain run-loop blocks. See [[main-queue-starved-by-modal-loops]] for the
mechanism and why adding modes to a dispatch hop changes nothing.

**Use it for** any main-thread hop that must run while a panel or alert is up:
a workspace close awaiting a lifecycle hook, a watcher-driven refresh, a
liveness probe, a continuation resume that a stalled UI must not block. The
deferral off the *current* turn is preserved — `CFRunLoopPerformBlock` never
runs the block inline — so it also serves callers that hop purely to get off
the current tick.

**Do not use it** where the hazard is re-entering a library mid-tick and the
main queue's inability to run inside the current tick is the point; see
[[osc52-clipboard-write-confirmation]] for the rule that picks between the two.

## Caveat: delayed hops

`Debouncer` in CasperCore schedules through `DispatchQueue.main.asyncAfter`, so
a debounced refresh stays pending until a modal panel is dismissed. CasperCore
does not link AppKit and cannot reach `MainRunLoop` (CasperUI) anyway. A delay
that must survive a panel measures its wait on a background queue and delivers
through `MainRunLoop.perform` — the shape `ScriptHookRunner`'s teardown
timeout uses.
