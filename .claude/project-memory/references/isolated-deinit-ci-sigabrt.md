---
name: "Avoid isolated deinit on @MainActor classes"
description: "isolated deinit's back-deploy shim SIGABRTs under XCTest on the CI runner; use a plain deinit + nonisolated(unsafe)"
type: feedback
---

# Avoid isolated deinit on @MainActor classes

Never use `isolated deinit` (SE-0371) on a `@MainActor` class. It forces the
Swift runtime to hop onto the main actor during deallocation through the
back-deployment shim `swift_task_deinitOnExecutorMainActorBackDeploy`, which
corrupts the heap and aborts with a SIGABRT (`*** error for object ...`) under
XCTest's memory checker on the headless GitHub Actions runner (intermittent,
flaky). The abort surfaces at test teardown, blamed on whichever unrelated test
happened to trigger the final dealloc.

**Why:** the back-deploy shim is only reached via `isolated deinit`; a plain
`deinit` never invokes it. The reason people reach for `isolated deinit` is that
a plain deinit on a `@MainActor` class cannot read a non-`Sendable` stored
property under Swift 6 strict concurrency. But by the time deinit runs, no other
reference to the object exists, so there is no concurrent access to race with.

**How to apply:** mark the stored properties the deinit needs to touch
`nonisolated(unsafe)` and use a plain `deinit`. This is proven in the codebase:
`Debouncer` (`Sources/CasperCore/Debouncer.swift`, `pending`) and
`WorkspaceShortcutKeyMonitor` (`Sources/CasperUI/WorkspaceShortcutKeyMonitor.swift`,
`eventMonitor`/`resignActiveObserver`) both use this pattern. Ensure the touched
API is itself thread-safe (e.g. `DispatchWorkItem.cancel()`, `NSEvent.removeMonitor`).
Related: [[swift6-network-concurrency]], [[mainactor-isolated-delegate-conformance]].
