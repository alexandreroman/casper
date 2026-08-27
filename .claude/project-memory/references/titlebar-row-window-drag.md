---
name: "A full-width toolbar item owns the title bar's drag and zoom"
description: "A ToolbarItem spanning the bar hides NSThemeFrame, so the row itself must carry WindowDragGesture, a contentShape over its spacers, and the AppleActionOnDoubleClick action"
type: reference
---

# A full-width toolbar item owns the title bar's drag and zoom

Dragging a window by its title bar and double-clicking that bar to zoom are
`NSThemeFrame` behaviours, and the theme frame only runs them for a mouse-down
it actually receives. A `ToolbarItem` whose hosted SwiftUI view spans the bar
leaves it nothing usable: measured on the running app, the row's
`NSToolbarItemViewer` spans 232..724 of a 736 pt bar and `hitTest:` across it
returns the SwiftUI hosting view. What the theme frame keeps is the bar left of
the row — traffic lights, sidebar toggle, the flexible space between them —
and the few points the row's own width undershoot leaves at the trailing edge. A
window whose
`styleMask` carries `.resizable`, whose `isMovable` is `YES` and whose `minSize`
is well under its frame is still immovable and unzoomable this way — the
window is healthy and the events never reach it.

So a title bar built as one item carries all three pieces itself, on the row,
below the `.frame(width:)` that gives it its definite width:

- **`.gesture(WindowDragGesture())`** (macOS 15+) restores the drag, and
  **only** the drag — it carries no double-click behaviour.
- **`.contentShape(Rectangle())`**, first, because a `Spacer` claims no hits of
  its own. The spacer separating the diff badge from the trailing chips is an
  inert stretch wide enough to be somewhere people aim, so without a shape over
  the row's rect a large part of the bar does not drag.

  That shape covers the hosted view's rect and **not** the toolbar item's full
  height, which is deliberate: the item viewer measures `f=(232,0,492,52)` while
  the SwiftUI hosting view inside it measures `f=(4,8,484,36)`, so the 8 pt
  strips above and below stay with the theme frame. The upper one is the
  window's top-edge resize band — a shape spanning the item's whole height
  takes the drag and gives up resizing the window from its top edge.
- **`.onTapGesture(count: 2)`** running the action named by the
  `AppleActionOnDoubleClick` user default. System Settings offers four —
  `"Fill"` takes the screen's `visibleFrame` and has no `NSWindow` verb of its
  own, `"Minimize"` miniaturizes, `"None"` does nothing, and `"Maximize"` (the
  string Zoom is stored under, and the unset default) zooms. The theme frame
  honours that choice, so hard-coding `performZoom` answers a question the user
  has already been asked.

  Guard the window before acting: `performZoom` and `performMiniaturize` BEEP at
  a window that cannot honour them, where the theme frame is silent. A window
  showing or belonging to a sheet, and a full-screen one, both qualify.

Both gestures stay **plain** — never `.highPriorityGesture`, never
`.simultaneousGesture`. A container's plain gesture yields to a child's own, so
the info chip, the Merge / Run / Editor chips and the inspector selector keep
clicking normally and only the inert parts of the row respond. Simultaneous is
actively wrong for the double-click: it fires on a double-click landing on a
chip and zooms the window out from under whoever hit it.

**Why:** the loss is silent and reads as a window bug rather than a toolbar one
— every window property looks correct under inspection, and the edges and
corners still resize, so only the two theme-frame gestures are missing.

**How to access:** the row is `WorkspaceTitleBarRow` in
`Sources/CasperUI/WorkspaceDetailView.swift`. The covering item is observable
from `lldb -p <pid>` against a debug build without any TCC grant: dump
`[[[window contentView] superview] _subtreeDescription]` for the viewer's frame,
and `hitTest:` a point in the bar to see which view answers. Synthetic pointer
input cannot verify the gestures — posting `CGEvent`s needs an Accessibility
grant the agent process lacks (see [[gui-synthetic-input]]) — so the drag and
the double-click are checked by the user against `make dev`.

Related: [[toolbar-overflows-before-squeezing]], [[title-capsule-hit-area]],
[[agent-visual-verification-limits]], [[window-floor-resizes-the-window]].
