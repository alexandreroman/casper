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
does drain run-loop blocks.

**Use it for** any main-thread hop that must run while a panel or alert is up:
a workspace close awaiting a lifecycle hook, a watcher-driven refresh, a
liveness probe, a continuation resume that a stalled UI must not block. The
deferral off the *current* turn is preserved — `CFRunLoopPerformBlock` never
runs the block inline — so it also serves callers that hop purely to get off
the current tick.

**Do not use it** where the hazard is re-entering a library mid-tick and the
main queue's inability to run inside the current tick is the point; see
[[osc52-clipboard-write-confirmation]] for the rule that picks between the two.

## Mechanism

The nested loop is entered from inside a main-queue block, and libdispatch
refuses to re-enter `_dispatch_main_queue_drain`, so everything queued behind
it waits until the modal ends. Mode membership is not the lever: adding
`NSModalPanelRunLoopMode` to a *dispatch* hop changes nothing, because the
limit is dispatch's re-entrancy guard. Only a run-loop block gets in.

CasperCore carries its own copy of the three CoreFoundation calls
(`MainThreadHangWatchdog`) because it does not link CasperUI. It spells
`NSModalPanelRunLoopMode` and `NSEventTrackingRunLoopMode` as string literals:
`RunLoop.Mode.modalPanel` / `.eventTracking` are declared by **AppKit**, which
CasperCore does not link either.

Corollary for any main-thread liveness probe: a main-queue round trip measures
"the main queue is draining", **not** "the main thread is alive". The two
differ for the whole duration of every modal and every menu track — which is
why `MainThreadHangWatchdog` acknowledges through a run-loop block. A
main-queue probe reports a UI freeze whenever "Check for Updates…" (Sparkle's
`runModal`) is up on a perfectly healthy app.

## Caveat: delayed hops

`Debouncer` in CasperCore schedules through `DispatchQueue.main.asyncAfter`, so
a debounced refresh stays pending until a modal panel is dismissed. CasperCore
does not link AppKit and cannot reach `MainRunLoop` (CasperUI) anyway. A delay
that must survive a panel measures its wait on a background queue and delivers
through `MainRunLoop.perform` — the shape `ScriptHookRunner`'s teardown
timeout uses.
