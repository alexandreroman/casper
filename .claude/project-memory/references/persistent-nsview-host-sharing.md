---
name: "PersistentNSViewHost shared-view ownership"
description: "One cached NSView per surface; a window-membership-driven coordinator converges it into the container actually in the window (splits, collapses, drag-relocate)"
type: reference
---

# PersistentNSViewHost shared-view ownership

Each terminal/browser surface is backed by exactly **one** cached `NSView`
(`AppModel.surfaceViews`, keyed by `Surface.id`) that keeps the PTY / web page
alive. `PersistentNSViewHost` (`Sources/CasperGhostty/PersistentNSViewHost.swift`)
re-parents that shared view into a fresh SwiftUI container on every rebuild.

Because the view is shared, any layout restructuring (split, **collapse**, or a
drag-**relocate** that reorders/nests the tree) momentarily leaves **two**
containers pointing at the same shared view — the incoming/surviving one and an
outgoing one SwiftUI is about to remove. Whichever container ends up detached
while holding the view leaves its pane **blank**.

**The mechanism:** a **window-membership-driven ownership coordinator**.
`SharedHostContainer` (an `NSView`) registers itself per shared view and calls
`SharedViewOwnership.reconcile(hostedView)` from `viewDidMoveToWindow()`. On every
window transition (a container entering **or** leaving a window), `reconcile`
places the shared view into the single registered container currently in a
window. This converges deterministically: an incoming container claims the view
when it enters the window (drag-relocate), and a survivor reclaims it when the
outgoing container leaves the window (collapse). `PersistentNSViewHost`'s
`makeNSView`/`updateNSView` just call `reconcile` — no unconditional re-attach.

**Do NOT** replace it with a one-shot `DispatchQueue.main.async` window-guarded
reconcile. Such a reconcile bails permanently (`guard container.window != nil
else { return }` with no retry) whenever it runs **before** the winning container
is added to the window — exactly what a drag-relocate does — orphaning the shared
view and blanking the pane for good. The event-driven coordinator has no such
timing race.

**Why:** any feature that renders **multiple** surfaces at once and restructures
the layout re-triggers this. The pre-tmux tab model rendered one surface per group
and never hit it. See [[surface-identity]] and
[[intra-app-drag-pasteboard-type]] (the pane drag-relocate feature that exposed
the drag-relocate blank-pane case).

**How to verify a regression:** with a debug build (see the `debug-casper` skill),
open ≥3 panes in a workspace and either close one (Ctrl-D / `exit`) or drag a pane
onto another repeatedly; every surviving pane must stay rendered (no black panes).
A cold relaunch renders a multi-pane layout fine, so reproduce via live
restructuring, not restore.
