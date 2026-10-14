---
name: "A full-width toolbar item owns the title bar's drag and zoom"
description: "A ToolbarItem spanning the bar hides NSThemeFrame, so a layer behind the row carries WindowDragGesture and the AppleActionOnDoubleClick action"
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
and the few points the row's own width undershoot leaves at the trailing edge.
A window whose `styleMask` carries `.resizable`, whose `isMovable` is `YES` and
whose `minSize` is well under its frame is still immovable and unzoomable this
way — the window is healthy and the events never reach it.

So a title bar built as one item hands both behaviours back to itself, on a
transparent layer **behind** the row — a `.background` below the
`.frame(width:)` that gives the row its definite width:

- **`Color.clear.contentShape(Rectangle())`** as the layer, because neither a
  clear colour nor a `Spacer` claims hits of its own. The spacer separating the
  diff badge from the trailing chips is an inert stretch wide enough to be
  somewhere people aim.

  The layer takes the row's frame, which is the hosted view's rect and **not**
  the toolbar item's full height. That is deliberate: the item viewer measures
  `f=(232,0,492,52)` while the SwiftUI hosting view inside it measures
  `f=(4,8,484,36)`, so the 8 pt strips above and below stay with the theme
  frame. The upper one is the window's top-edge resize band — a shape spanning
  the item's whole height takes the drag and gives up resizing the window from
  its top edge.
- **`.gesture(WindowDragGesture())`** (macOS 15+) restores the drag, and
  **only** the drag — it carries no double-click behaviour.
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

The row itself carries **no** gesture and **no** `contentShape`, and the
branch/Space title carries `.allowsHitTesting(false)`. A click on a chip hits
only the chip; a click anywhere inert — the title, the spacer, the gaps, the
info button's collapsed slot — falls through to the layer. The title needs the
opt-out because its text takes the clicks that land on it, and a row-level
`contentShape` would likewise make the row the hit target and starve the layer.
Any other hit-testable background on the row (the DEBUG `TitleBarRungReporter`)
must stay `.allowsHitTesting(false)` for the same reason.

Placement is what protects the chips. A gesture on an **ancestor** of the chips
takes part in every chip click, whatever its priority: a plain one delays the
chip button's `isPressed` until SwiftUI rules the gesture out — the double-tap
waits out a possible second click — so the pressed state of
`TitleChipButtonStyle` lands late while the action still fires; a
high-priority one steals the click; a simultaneous one fires alongside it, so a
double-click on a chip zooms the window out from under whoever hit it. On a
sibling layer behind the row, both gestures stay plain and touch no chip.

**Why:** the loss of the theme-frame gestures is silent and reads as a window
bug rather than a toolbar one — every window property looks correct under
inspection, and the edges and corners still resize, so only the two gestures
are missing. The press delay is just as quiet: every click still works, and
only the feedback lags, measurably — with the gestures removed from the row the
pressed state is instant.

**How to access:** the row is `WorkspaceTitleBarRow` in
`Sources/CasperUI/WorkspaceTitleBar.swift`. The covering item is observable
from `lldb -p <pid>` against a debug build without any TCC grant: dump
`[[[window contentView] superview] _subtreeDescription]` for the viewer's frame,
and `hitTest:` a point in the bar to see which view answers. Synthetic pointer
input cannot verify the gestures — posting `CGEvent`s needs an Accessibility
grant the agent process lacks (see [[gui-synthetic-input]]) — so the drag, the
double-click and the press timing are checked by the user against `make dev`.

Related: [[toolbar-overflows-before-squeezing]], [[title-capsule-hit-area]],
[[agent-visual-verification-limits]], [[window-floor-resizes-the-window]].
