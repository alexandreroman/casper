---
name: "Headless teardown-hook tests"
description: "The teardown split spawns fine in a unit test; only the child-exit event has to be driven by hand"
type: project
---

# Headless teardown-hook tests

A workspace's `teardown` lifecycle hook is unit-testable without a live
libghostty surface. `ScriptHookRunner.spawnScriptSurface` is a **pure layout
mutation** — it inserts a `Surface.terminal` into the workspace's layout tree
and records it in `scriptSurfaces` — so `runTeardown` reaches its wait state in
a headless XCTest run exactly as it does in the app. What does not happen
headlessly is the child exiting: no PTY runs, so nothing ever calls back.

The recipe (see `Tests/CasperUITests/CloseDeleteWorkspaceTests.swift`):

1. Commit a `.casper.json` carrying only a `teardown` script into the fixture
   repo **before** creating the linked workspace, so the worktree checks it out.
   Adding a `setup` script too would spawn a second script split at creation.
2. Snapshot `LayoutTree.surfaceIDs(ws.layout)` before starting the close/delete.
3. Start the operation in a `Task { @MainActor in … }`, then poll (bounded, ~5
   ms steps) for the one surface id that is new.
4. Call `model.handleScriptSurfaceExit(newSurfaceID, code:)` — the exact entry
   point `GhosttySurfaceView.onChildExit` uses at runtime — to end the hook.

`AppModel.reportTeardownHookFailure` is internal rather than private for the
same reason: its only production callers are the two confirmation presenters,
which run an `NSAlert` modally and therefore cannot run headlessly, so a test
that wants to assert the teardown-failure notification calls it the way the
presenters do.

**Why:** without this, the whole hook-present branch (step counts, the countdown
deadline, the failure notification) looks untestable and gets left to manual
verification — and a test that forgets step 4 stalls on the 30 s
`ScriptHookRunner.teardownTimeout` instead of failing.

**How to apply:** when covering anything behind `runTeardown`, drive
`handleScriptSurfaceExit` rather than faking the hook status; keep the poll
bounded so a broken run fails in milliseconds instead of stalling for the
timeout.
