---
name: "Workspace selection invariant"
description: "A non-empty spaces list always has a resolvable selectedWorkspaceID; the homepage shows only when spaces is empty"
type: reference
---

# Workspace selection invariant

When `AppModel.spaces` is non-empty, `selectedWorkspaceID` is always non-nil and
resolves to a live workspace. Guaranteed by: `addSpace` selects the new Space's
primary workspace; `fallbackSelection` re-selects the first remaining workspace
after any removal; session restore falls back to
`spaces.first?.workspaces.first`; and a Space always holds at least one
workspace (a primary can't be dropped via `removeWorkspace`, and closing a
primary's last surface removes the whole Space). Locked by `AppModelTests`
(add/remove/restore selection cases).

Consequences:

- The empty-session homepage (`EmptyStateView`) renders **only** when
  `spaces.isEmpty` — first launch or after every Space is removed. So its copy
  is evergreen/instructional, not first-run "welcome" language.
- `RootView`'s detail-pane `else` branch is therefore unreachable; it is a
  defensive `Color.clear`, not the homepage.

Soft spot to watch: `selectWorkspace(_:)` assigns `selectedWorkspaceID`
**before** validating the id, so the invariant holds only because every current
caller pre-validates (e.g. `AppDelegate` guards explicitly). A future caller
that skips validation would silently reintroduce a dangling selection that the
defensive `Color.clear` dead branch would otherwise mask.
