---
name: "PersistentNSViewHost shared-view ownership"
description: "One cached NSView per surface; a window-membership-driven coordinator converges it into the container actually in the window (splits, collapses, drag-relocate)"
type: reference
---

# PersistentNSViewHost shared-view ownership

Each terminal/browser surface is backed by exactly **one** cached `NSView`
(`AppModel.surfaceViews`, keyed by `Surface.id`) that keeps the PTY / web page
alive. `PersistentNSViewHost`
(`Sources/CasperGhostty/PersistentNSViewHost.swift`) re-parents that shared view
into a fresh SwiftUI container on every rebuild.

Because the view is shared, any layout restructuring (split, **collapse**, or a
drag-**relocate** that reorders/nests the tree) momentarily leaves **two**
containers pointing at the same shared view — the incoming/surviving one and an
outgoing one SwiftUI is about to remove. Whichever container ends up detached
while holding the view leaves its pane **blank**. `SharedViewOwnership` and its
`SharedHostContainer` are the window-membership coordinator that resolves that;
their doc comments carry the mechanism and the timing race a one-shot
`DispatchQueue.main.async` reconcile loses.

**Why it stays load-bearing:** every feature that renders **multiple** surfaces
at once and restructures the layout re-triggers this class of bug. See
[[surface-identity]] and [[intra-app-drag-pasteboard-type]] (the pane
drag-relocate that exposes the blank-pane case).

**How to verify a regression:** with a debug build (see the `debug-casper`
skill), open ≥3 panes in a workspace and either close one (Ctrl-D / `exit`) or
drag a pane onto another repeatedly; every surviving pane must stay rendered (no
black panes). A cold relaunch renders a multi-pane layout fine, so reproduce via
live restructuring, not restore.
