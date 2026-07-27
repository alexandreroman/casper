---
name: "Nested modal loops starve the main dispatch queue"
description: "DispatchQueue.main.async never runs during runModal/menu tracking; reach the main thread with CFRunLoopPerformBlock instead"
type: reference
---

# Nested modal loops starve the main dispatch queue

While the main thread sits in a nested run loop — `-[NSAlert runModal]`,
`-[NSOpenPanel runModal]`, `NSApplication runModalForWindow:`, menu or drag
tracking — **blocks queued with `DispatchQueue.main.async` do not run**. The
nested loop is entered from inside a main-queue block, and libdispatch refuses
to re-enter `_dispatch_main_queue_drain`, so everything queued behind it waits
until the modal ends. Adding `NSModalPanelRunLoopMode` to the run loop changes
nothing: the limit is dispatch's re-entrancy guard, not mode membership.

**Reach the main thread anyway** with a run loop block, which the nested loop
does drain:

```swift
CFRunLoopPerformBlock(CFRunLoopGetMain(), modes, block)
CFRunLoopWakeUp(CFRunLoopGetMain())  // else a sleeping loop waits for an event
```

where `modes` is a `CFArray` of `kCFRunLoopCommonModes`,
`NSModalPanelRunLoopMode` and `NSEventTrackingRunLoopMode`. Spell the last two
as string literals in CasperCore: `RunLoop.Mode.modalPanel` / `.eventTracking`
are declared by **AppKit**, not Foundation, which CasperCore does not link.
Build the modes array once; `CFRunLoopPerformBlock` is thread-safe.

**Where this bit us:** `MainThreadHangWatchdog` probed main-thread liveness with
`DispatchQueue.main.async`, so "Check for Updates…" (Sparkle's `runModal`)
produced a "Casper UI freeze captured" notification on a perfectly healthy app.
Casper's own `runModal()` panels and alerts in `AppModel+Presentation` have the
same shape. See [[hang-dump-watchdog]].

Corollary for any main-thread liveness probe: a main-queue round trip measures
"the main queue is draining", **not** "the main thread is alive". The two differ
for the whole duration of every modal and every menu track.
