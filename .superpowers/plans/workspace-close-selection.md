# Auto-Reselect on Workspace Close — Design

**Date:** 2026-07-09
**Status:** Design
**Scope:** When a workspace is removed from the session (deleted outright,
closed via merge, or dropped along with its whole Space), the UI selection
must never be left dangling or reset to nothing when a reasonable alternative
exists. Selection should prefer a sibling workspace in the same Space, falling
back to the first workspace of the first remaining Space.

## Problem

`AppModel.selectedWorkspaceID: UUID?` (`AppModel.swift:18`) is repaired in
exactly two places today — `removeWorkspace(id:)` (`AppModel.swift:465`) and
`removeSpace(id:)` (`AppModel.swift:362`) — both of which fall back to:

```swift
selectWorkspace(spaces.first?.workspaces.first?.id)
```

This is a "jump to the alphabetically-first Space's insertion-order-first
workspace" policy, with two problems:

1. It never prefers a sibling workspace in the *same* Space as the one just
   removed — closing a linked workspace can bounce the user's selection to an
   entirely unrelated Space even though a sibling (or the primary) is sitting
   right there in the same Space.
2. It uses `Space.workspaces` (raw insertion order), not
   `Space.orderedWorkspaces` (`Models.swift:375-382`, the primary-first,
   then-alphabetical order the sidebar actually renders) — so the "first"
   workspace picked is not always the one that appears first visually.

Every removal path — `casper workspace delete` (CLI), "Delete Workspace…"
(UI), "Merge and Close Workspace…" (UI), and closing a workspace's last
terminal pane — funnels through these same two functions
(`pruneWorkspaceFromDisk` → `removeWorkspace`, or `applyCloseSurface` →
`removeWorkspace`/`removeSpace` directly), so fixing the fallback in these two
places fixes selection behavior everywhere.

## Goals

- When the **selected** workspace is removed, selection moves to:
  1. The first remaining workspace in the **same Space**, in display order
     (`Space.orderedWorkspaces`), if the Space still has other workspaces.
  2. Otherwise, the first workspace of the first remaining Space (`spaces`
     is kept sorted alphabetically by name), also in display order.
  3. Otherwise (no Spaces left at all), `nil`.
- `removeSpace`'s existing global fallback is updated to the same display-order
  convention, for consistency (it currently uses insertion order too).
- No behavior change for the non-selected case: closing a workspace that
  isn't currently selected never touches `selectedWorkspaceID`.

## Non-Goals

- No change to *how* Spaces are ordered (`spaces` stays alphabetically
  sorted) or to `orderedWorkspaces` itself (primary first, then linked
  alphabetically) — both already exist and are reused as-is.
- No change to which workspaces are removable (`removeWorkspace` still
  refuses to remove a primary workspace; that guard is untouched).
- No new CLI verb or control-channel command — this only changes what
  happens to selection state inside the existing removal primitives.

## Design

### New helper on `AppModel`

```swift
private func fallbackSelection(preferring space: Space?) -> UUID? {
    space?.orderedWorkspaces.first?.id ?? spaces.first?.orderedWorkspaces.first?.id
}
```

Placed near `removeWorkspace`/`removeSpace` in `AppModel.swift`. Returns `nil`
only when there is no candidate anywhere (`preferring` space empty or absent,
and no Spaces remain) — matching the existing invariant (asserted today by
`assertSelectionValidOrNil` in `AppModelTests.swift`) that selection must be
`nil` or resolve to a live workspace, never dangle.

### `removeWorkspace(id:)` (`AppModel.swift:465`)

Change the fallback call from:

```swift
if selectedWorkspaceID == id {
    selectWorkspace(spaces.first?.workspaces.first?.id)
}
```

to:

```swift
if selectedWorkspaceID == id {
    selectWorkspace(fallbackSelection(preferring: spaces[at.space]))
}
```

`spaces[at.space]` is the Space the removed workspace belonged to, already
mutated (the linked workspace has already been removed from its
`workspaces` array by this point) — so `orderedWorkspaces.first` on it is
exactly "the first remaining sibling in the same Space." Because
`removeWorkspace` only ever removes a *linked* workspace (the primary-removal
guard is unchanged), the Space always retains at least its primary, so this
branch always resolves to a same-Space sibling in current practice — the
`?? spaces.first...` term is defensive, not dead code, for consistency with
`removeSpace`'s call shape and in case that invariant ever changes.

### `removeSpace(id:)` (`AppModel.swift:362`)

Change the fallback call from:

```swift
if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
    selectWorkspace(spaces.first?.workspaces.first?.id)
}
```

to:

```swift
if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
    selectWorkspace(fallbackSelection(preferring: nil))
}
```

The Space itself is gone here, so there is no "same Space" to prefer — this
always resolves via the `spaces.first?.orderedWorkspaces.first?.id` branch,
now in display order instead of insertion order.

### Unaffected

- `selectWorkspace(_:)` itself (`AppModel.swift:490`) — still the single
  assignment point; unchanged.
- `pruneWorkspaceFromDisk`, `deleteWorkspace`, `closeWorkspace`,
  `controlDeleteWorkspace`, `presentDeleteWorkspaceConfirmation`,
  `presentCloseWorkspaceConfirmation` — all inherit the fix automatically via
  `removeWorkspace`/`removeSpace`; no direct changes needed.
- `applyCloseSurface` — still decides *whether* to call `removeWorkspace` or
  `removeSpace`; only what those two do internally changes.

## Testing

- `Tests/CasperUITests/AppModelTests.swift`:
  - New test: a Space with a primary + two linked workspaces; select one
    linked workspace, remove it via `removeWorkspace`; assert selection
    lands on the *other* remaining sibling in that same Space (in display
    order), not on a workspace in a different Space — proving the same-Space
    preference actually engages instead of falling through to the global
    fallback.
  - Existing tests (`testRemoveDeletesEntryAndFixesSelection`,
    `testRemovingSelectedSpaceLeavingNoneClearsSelection`,
    `testRemovingSelectedLinkedWorkspaceReselectsValidWorkspace`) continue to
    pass unchanged — they only exercise degenerate cases (single remaining
    workspace, or zero Spaces left) where the new logic and the old logic
    agree.
- `Tests/CasperUITests/CloseDeleteWorkspaceTests.swift`:
  - Extend coverage to assert `selectedWorkspaceID` after `closeWorkspace`
    and `deleteWorkspace` on a *selected* linked workspace that has sibling
    workspaces in its Space — this file currently has no assertions on
    selection at all.
- Manual verification via `make dev` / `debug-casper`: create a Space with a
  primary and two linked workspaces, select a linked workspace, delete it —
  confirm the sidebar selection highlight moves to the sibling in the same
  Space, not to an unrelated Space.
