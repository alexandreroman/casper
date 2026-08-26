---
name: "DEBUG memory observability"
description: "The live-object census, the casper debug memory verb and the churn script — plus where tracking cannot live"
type: reference
---

# DEBUG memory observability

A `#if DEBUG` instrumentation path answers "does closing a terminal give the
memory back?" without a profiler:

- `CasperCore/LiveObjectCensus` counts live instances of tracked classes. It
  stores a **weak** reference per object, so a tracked class needs neither a
  token property nor a `deinit` hook, and the census can never keep an object
  alive. Both `track(_:)` and `snapshot()` compact the dead slots, so storage
  stays bounded by the live population whether or not anything ever samples:
  `track` re-compacts once the slots grow past twice the live count it last
  measured, which is what stops an unsampled session from accumulating one slot
  per object ever tracked. A label whose population has fallen to zero is still
  reported — that zero is the signal.
- `CasperCore/ProcessMemory.sample()` reads `task_vm_info`'s `phys_footprint`
  (the number Activity Monitor shows), `resident_size` and
  `ledger_phys_footprint_peak`. A failed `task_info` returns `nil` — never a
  trap, and never an all-zero sample that would read as a healthy 0 MB
  measurement — and the `memory` verb then answers `task_info failed` rather
  than an `ok` reply.
- `casper debug memory` returns both, plus `counters` — the sizes of the app's
  per-id caches and layout collections. `AppModel.debugMemoryCounters()`
  (`DebugSurfaceBridge.swift`) builds them; `DebugServer` adds `nsWindows`
  itself, since that is a property of the process rather than of the model.
  `DebugServer` reaches the counters by conditionally casting its stored
  `DebugSurfaceProvider` to `DebugMemoryProvider`, so a provider that serves
  surfaces only stays valid.
- `Scripts/memory-watch.sh sample|churn` drives that verb against a running dev
  instance and tabulates the growth. `churn` opens and closes a terminal N times
  between two samples.

**Where tracking cannot live.** `LiveObjectCensus` is `@MainActor`, matching the
AppKit objects it counts, so `track(_:)` is only reachable from main-actor
context:

- `GhosttySurface` has a **nonisolated** `init` (the class is main-thread affine
  by contract only), so Swift 6 rejects passing `self` to the census from there.
  It is tracked from `GhosttySurfaceView.createSurfaceIfNeeded()` instead — the
  only
  place that constructs one.
- `DirectoryWatcher` is `@unchecked Sendable` with a genuinely off-main design,
  so it is not tracked at all rather than asserting an isolation it does not
  claim.

**Why:** the census is the half that distinguishes a real leak from allocator
noise — a footprint that grows while every live count returns to baseline is not
a leak. Related: [[debug-channel-gating]] (why all of this is `#if DEBUG`),
[[appmodel-extension-encapsulation]] (`surfaceViews` stays private behind a
`debugSurfaceViewCount` accessor).
