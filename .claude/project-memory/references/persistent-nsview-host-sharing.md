---
name: "PersistentNSViewHost shared-view collapse gotcha"
description: "One cached NSView per surface; a layout collapse can let a stale SwiftUI host steal it — window-guarded deferred reconcile guards it"
type: reference
---

# PersistentNSViewHost shared-view collapse gotcha

Each terminal/browser surface is backed by exactly **one** cached `NSView`
(`AppModel.surfaceViews`, keyed by `Surface.id`) that keeps the PTY / web page
alive. `PersistentNSViewHost` (`Sources/CasperGhostty/PersistentNSViewHost.swift`)
re-parents that shared view into a fresh SwiftUI container on every rebuild.

Because the view is shared, a **layout collapse** (a split folding back to a
single leaf, e.g. after closing a pane) momentarily leaves **two** hosts pointing
at it: the surviving host and the outgoing host still in the `HSplitView` subtree
SwiftUI is about to remove. The outgoing host's `updateNSView` sees the view moved
(`view.superview !== container`) and **steals it back** into its own container —
which SwiftUI then removes from the window. The shared view lands in a detached
container and the surviving pane goes **blank**.

**The guard:** after each attach, `PersistentNSViewHost` schedules a next-runloop,
**window-guarded reconcile** (`DispatchQueue.main.async { guard container.window
!= nil …; re-attach if the view was stolen }`). Only a host whose container is
still in the window keeps the view; a stale host (already out of the window)
yields. Do not remove this deferral.

**Why:** any feature that renders **multiple** surfaces at once and restructures
the layout (splits, collapses, reorders) re-triggers this. The pre-tmux tab model
rendered only one surface per group at a time and never hit it. See
[[surface-identity]].

**How to verify a regression:** with a debug build (see the `debug-casper` skill),
open ≥2 panes in a workspace, close one (Ctrl-D / `exit`); the survivor must stay
rendered — `casper debug dump-state` reports **≥1** surface (a regression shows
**0** and a blank detail area).
