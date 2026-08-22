---
name: "Pane views are threaded by workspace id and layout"
description: "The pane tree takes a workspace id plus a LayoutNode, never a Workspace value, so an agent tick cannot invalidate it"
type: feedback
---

# Pane views are threaded by workspace id and layout

`WorkspaceDetailView` and every view below it — `LayoutNodeView`,
`SplitContainerView`, `SurfaceHostView` — take the workspace's **id** (`UUID`)
and the pieces of its **layout** they render. A `Workspace` value never becomes
a stored property of a pane view.

**Why:** `Workspace` is `Equatable` and carries the transient agent fields
(`agentState`, `todos`, `pendingNotification`, `pendingNotificationMessage`,
`infoMarkdown`, `infoUnread`) in the same value as `layout`. The panes render
none of them, but SwiftUI compares stored properties: a `Workspace` held by a
pane view changes on every OSC 9;4 agent tick, so SwiftUI re-runs the body of
the whole pane subtree — including each `SurfaceHostView` wrapping a live
terminal — for a state change nothing in it displays.

The same reasoning shapes `AppModel.surfaceView(for:in:)`, which takes a
workspace id rather than a `Workspace`. It resolves the workspace via
`workspace(id:)` *below* the `surfaceViews` cache-hit return, because the value
is needed only to build a brand-new surface's environment. The steady-state
call — the one a pane body makes on every render — returns from the cache
without ever reading `spaces`, so it registers no Observation dependency on the
agent fields.

**How to apply:** thread ids down the pane tree and resolve values as late as
possible, under the early return that the common path takes. When a pane view
needs something derived from the workspace, pass that derived value (as
`canDragPanes` does) rather than the workspace it came from. An `@Observable`
read placed above a cache-hit return subscribes the caller to everything that
property touches, so ordering is part of the contract, not a style choice.

`Tests/CasperUITests/PaneTreeInputsTests.swift` pins the invariant: it ticks the
agent state, rebuilds the three pane views from the before/after workspaces, and
compares their stored properties by `Mirror`. Its negative control feeds the
same comparison a view that does store a `Workspace` and asserts the mismatch
is reported, so a green run means the properties are genuinely stable rather
than the reflection being blind to them.

See also [[surface-identity]] — the id the surface-view cache is keyed by —
and [[background-surface-nursery]], which drives that same cache from outside
any pane body.
