---
name: "Background surface nursery for unselected-workspace commands"
description: "Unselected workspaces have no live PTY; queued commands run via an off-screen nursery window"
type: project
---

# Background surface nursery for unselected-workspace commands

An unselected workspace has **no live terminal surface at all**: libghostty
surfaces (and their PTYs) are created lazily in `GhosttySurfaceView`, gated on
`viewDidMoveToWindow` / `createSurfaceIfNeeded` requiring `window != nil`, and
only the *selected* workspace's views are ever mounted (`RootView` builds only
the selected workspace's detail). So a workspace created silently via the
control channel (`casper workspace new --command`, `select: false`) had its
command sit unconsumed in `pendingInitialInput` until the user selected it.

To run such commands in the background **without stealing the selection**,
`AppModel` hosts the new workspace's pending-input surfaces in an off-screen
`backgroundSurfaceNursery` (borderless `NSWindow` parked at -100_000, mirroring
`BrowserCapture`). Hosting drives surface creation → PTY spawn → the queued
command. When the workspace is later selected, the existing
`SharedViewOwnership.reconcile` (in `PersistentNSViewHost.swift`) reparents the
cached view out of the nursery into the visible container. See
`materializePendingSurfacesOffscreen(in:)`; `discardSurfaceViews` detaches
nursery-hosted views so a never-selected workspace's PTY is freed.

Three call sites drive it, each owning exactly the surfaces whose input it
queued — never overlapping, so none can be dropped as redundant:

- `createLinkedWorkspace`, guarded on `!select, command != nil` — the initial
  terminal's `--command`.
- `controlOpenTerminal`, guarded on `command != nil` and non-selected — a
  `--command` opened into a background workspace.
- `insertHookSurface`, guarded on non-selected — every `.casper.json`
  `setup`/`teardown` split. Without it, deleting a **non-selected** workspace
  whose repo defines a `teardown` hook always burned the full 30 s
  `ScriptHookRunner.teardownTimeout`: the split was inserted into the layout but
  never mounted, so no PTY spawned, no child-exit arrived, and only the timeout
  could resume `runTeardown`. `ScriptHookRunner` stays ignorant of views — the
  materialization lives on the `AppModel` side of its injected-closure seam.

**Why:** the lazy, window-gated surface lifecycle is the reason background
commands (and CLI-created workspaces' `setup` hooks, same `pendingInitialInput`
path) don't run on their own — an easy invariant to miss when touching
workspace creation or surface lifecycle.

**How to apply:** anything that must run in an unselected workspace's terminal
needs its surface materialized (via the nursery) — merely queueing input or
splitting is not enough until the workspace is selected. Off-screen surfaces
read as occluded (render paused), but the PTY still runs. See also
[[surface-identity]], [[persistent-nsview-host-sharing]],
[[observed-startup-dependencies]].
