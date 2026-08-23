---
name: "Only the layout may create a surface view"
description: "surfaceView(for:in:) builds a view only for a Surface the layout still holds, so closed panes leak none"
type: feedback
---

# Only the layout may create a surface view

`AppModel.surfaceView(for:in:)` creates a `GhosttySurfaceView` only for a
surface the resolved workspace's layout still holds. A `Surface` value that is
no longer in the layout gets `nil`.

**Why:** `SurfaceHostView` stores the `Surface` **value** captured when the pane
tree was built, not a live lookup. Closing a pane runs `applyCloseSurface`,
which drops the surface from the layout and calls `discardSurfaceViews` to empty
its cache slot — and *then* SwiftUI evaluates the departing view's body one last
time with that stale value. Without the guard, that final body pass builds a
brand-new view and refiles it under the id of a surface the model has forgotten.
Nothing prunes it afterwards, so every closed terminal permanently costs one
`GhosttySurfaceView`: an `NSView`, closures retaining `AppModel`, and the
process-wide `NSEvent.addLocalMonitorForEvents(matching: .keyUp)` its `init`
installs, which then runs on every command-key release for the rest of the
session. The zombie never enters a window, so it spawns no libghostty surface
and no PTY — the leak is invisible to any PTY or `GhosttySurface` count, and
shows up only as a growing `surfaceViews` cache.

**How to apply:** the membership guard sits **below** the `surfaceViews`
cache-hit return and below `workspace(id:)`, so a mounted pane's every-render
call still returns from the cache without walking anything — only genuine
creation pays for the walk. That ordering is part of the contract (see
[[pane-tree-inputs]] for the sibling reason the workspace is resolved late).
The walk is `LayoutTree.contains(_:id:)`, which early-exits at the first match
rather than materializing `surfaceIDs`. The departing pane renders `Color.black`
for the nil and then disappears.

The guard is the whole fix: no tombstone set, no timer, no periodic sweep of the
cache. Callers that drive the cache from outside a pane body — the background
nursery's `materializePendingSurfacesOffscreen` — pass a `Workspace` re-resolved
from the model and iterate that same layout, so membership always holds for
them.

`AppModelTests.testSurfaceViewDoesNotRecreateAViewForAClosedSurface` pins it by
closing a pane and re-asking with the stale `Surface`, asserting both the nil
and an unchanged `debugSurfaceViewCount`.
