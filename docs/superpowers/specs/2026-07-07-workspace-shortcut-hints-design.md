# Design: Cmd-hold workspace-switch shortcuts

**Status:** approved · **Date:** 2026-07-07 · **Module:** CasperUI (+ AppDelegate wiring)

## Problem

There is no way to jump directly to a sidebar workspace from the keyboard today.
`grep` across the repo confirms no `Cmd+1…9` binding exists anywhere, and no
concept of a numeric "workspace index" exists on `AppModel`, `Space`, or
`Workspace`.

## Goal

Holding <kbd>Cmd</kbd> for at least 1 second reveals a keyboard-shortcut hint
(`⌘1`, `⌘2`, …) in each of the first nine visible sidebar workspace rows, in
the same trailing slot normally occupied by the notification bubble. Releasing
<kbd>Cmd</kbd> hides the hints. Pressing `Cmd+N` (1-9) at any time — whether or
not the hint has appeared yet — switches to the corresponding workspace.

## Non-goals

- No support for more than 9 numbered workspaces (per spec, list is capped at
  1-9; workspaces beyond the 9th simply have no shortcut and are unaffected).
- No global (system-wide) shortcut — only active while Casper is the focused
  app.
- No user-configurable rebinding of the shortcuts.

## Numbering rule

A single flat ordering across the whole sidebar (not per-space):

1. Walk `AppModel.spaces` in display order.
2. **Skip collapsed spaces entirely** — their workspaces consume no numbers
   while hidden.
3. Within each visible space, walk `space.orderedWorkspaces` (existing order:
   primary workspace, then linked workspaces alphabetically).
4. Flatten into one list; take the first 9 entries → numbers 1-9.

This produces a lookup used by both the UI hint and the actual switch action,
so `Cmd+3` always targets whichever row is currently showing `⌘3` — the hint
and the behavior cannot drift apart. Expanding/collapsing a space while hints
are visible re-numbers reactively (the ordering is a computed property, and
`AppModel` is `@Observable`).

## Detection & timing

A local key monitor — installed once from `AppDelegate` alongside the existing
`FileMenu`/`AppModel` wiring, using `NSEvent.addLocalMonitorForEvents` — handles
two independent things:

- **`.flagsChanged`**: tracks Command key state.
  - Command down → start a 1.0s `Timer`.
  - Command still down when the timer fires → set
    `AppModel.showWorkspaceShortcutHints = true` inside `withAnimation`.
  - Command released at any point (before or after the timer fires) →
    immediately set the flag back to `false` and invalidate any pending timer.
- **`.keyDown`**: if Command is held (and no other modifiers) and the key is
  `1`…`9`, call `AppModel.selectWorkspace(atShortcutNumber:)` with the digit.
  This fires regardless of whether the 1s hint has appeared — the hint is a
  discoverability aid, not a gate on the behavior.

Local monitor scope means this only fires while a Casper window is key; no
Accessibility permission is required, and there is no interaction with other
apps' Cmd+number shortcuts.

## AppModel changes

- `showWorkspaceShortcutHints: Bool` (plain `@Observable`-tracked property,
  default `false`).
- A computed ordering (private helper) implementing the numbering rule above,
  exposed as a `[Workspace.ID: Int]`-shaped lookup (or equivalent) that
  `SidebarView` reads once per render when building rows.
- `selectWorkspace(atShortcutNumber number: Int)`: looks up the workspace at
  that position in the same ordering and delegates to the existing
  `selectWorkspace(_:)`. A miss (e.g. `Cmd+7` with only 4 workspaces) is a
  no-op.

## UI changes (`WorkspaceRow` / `SidebarView`)

- `SidebarView.row(for:in:)` computes the shortcut number for each workspace
  (from the `AppModel` lookup) and passes it into `WorkspaceRow` alongside the
  existing parameters.
- `WorkspaceRow`'s trailing slot (currently always `NotificationBubble`, driven
  by `workspace.pendingNotification`) becomes a swap:
  - `model.showWorkspaceShortcutHints == true` **and** the row has an assigned
    number → show `⌘N` text in that slot.
  - otherwise → existing `NotificationBubble` behavior, unchanged.
- Swap animation: `.transition(.opacity)` combined with
  `.animation(.easeInOut(duration: 0.15), value: model.showWorkspaceShortcutHints)`,
  matching the easing style already used for the bubble's pulse
  (`.easeInOut(duration: 0.8)`) and the folder-button press feedback
  (`.easeOut(duration: 0.12)`) elsewhere in this file — same family, snappier
  duration since this is a direct response to a key press rather than an
  ambient/looping animation.

## Testing

- Unit test the numbering rule on `AppModel` (or wherever it lands): flat
  ordering across multiple spaces, collapsed-space exclusion, 9-item cap, and
  `selectWorkspace(atShortcutNumber:)` resolving to the right workspace /
  no-op past the end.
- Manual verification (per project convention, `make dev` + the `verify` /
  `debug-casper` workflow): hold Cmd for 1s and confirm hints fade in on the
  first 9 rows in the right slot, collapse a space and confirm renumbering,
  release Cmd and confirm hints fade out, and confirm `Cmd+N` switches
  workspaces both before and after the 1s hint appears.

## Open implementation questions (for the plan, not blocking this spec)

- Exact home for the key monitor (a new small file vs. inline in
  `AppDelegate`) — a call the implementation plan can make while reading the
  current `AppDelegate.swift`/`FileMenu.swift` structure.
- Whether the numbering lookup is precomputed as a dictionary once per
  `SidebarView` render or exposed as a `func(Workspace.ID) -> Int?` — an
  implementation detail with no behavioral difference.
