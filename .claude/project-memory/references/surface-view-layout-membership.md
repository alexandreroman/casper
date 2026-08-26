---
name: "Only the layout may create a surface view"
description: "surfaceView(for:in:) builds a view only for a Surface the layout still holds, so closed panes leak none"
type: feedback
---

# Only the layout may create a surface view

`AppModel.surfaceView(for:in:)` creates a `GhosttySurfaceView` only for a
surface the resolved workspace's layout still holds; the guard and its rationale
are on the call itself.

**What the code does not say:** the leak that guard prevents is invisible to
every count that would normally catch one. A zombie view never enters a window,
so it spawns no libghostty surface and no PTY — a PTY census or a
`GhosttySurface` count both read clean, and the only observable is a growing
`surfaceViews` cache. Budget an assertion on `debugSurfaceViewCount`, not on
process state.

**How to apply:** the membership walk is `LayoutTree.contains(_:id:)`, which
early-exits at the first match rather than materializing `surfaceIDs` — keep it
that way, since it sits on the creation path of every pane. Its position below
the cache-hit return and below `workspace(id:)` is part of the contract (see
[[pane-tree-inputs]] for the sibling reason the workspace is resolved late).

The guard is the whole fix: no tombstone set, no timer, no periodic sweep of the
cache. Callers that drive the cache from outside a pane body — the background
nursery's `materializePendingSurfacesOffscreen` — pass a `Workspace` re-resolved
from the model and iterate that same layout, so membership always holds for
them.

`AppModelTests.testSurfaceViewDoesNotRecreateAViewForAClosedSurface` pins it by
closing a pane and re-asking with the stale `Surface`, asserting both the nil
and an unchanged `debugSurfaceViewCount`.
