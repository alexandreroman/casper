---
name: "Cursor management for chrome over the terminal"
description: "AppKit chrome layered over libghostty must set the cursor via cursorUpdate AND mouseEntered, reset to arrow on exit; never push/pop or addCursorRect alone"
type: reference
---

# Cursor management for chrome over the terminal

Any AppKit view layered over the libghostty terminal (e.g. the pane drag grip
`PaneDragHandleView` in `Sources/CasperUI/PaneDragAndDrop.swift`) must manage
its cursor the way `GhosttySurfaceView` does:

- A tracking area with `.cursorUpdate`, and set the cursor in **both**
  `cursorUpdate(with:)` **and** `mouseEntered(with:)`.
- Reset to `NSCursor.arrow.set()` in `mouseExited(with:)` so the cursor does not
  leak onto sibling chrome; the terminal restores its I-beam via its own
  `cursorUpdate` when the pointer moves back onto it.

**Why:** two AppKit cursor mechanisms fail here and cost real debugging time.
`NSCursor.push()`/`pop()` uses a global stack that leaks whenever a view is torn
down mid-hover/drag (the layout reparents constantly) and restores the wrong
base. `addCursorRect`/`resetCursorRects` is **not re-applied** when the pointer
enters from a region that defines no cursor rect of its own — notably the
**native window toolbar** (`.toolbar { ToolbarItem(.navigation) }`) directly
above the top pane — so the hand cursor never appears on that downward entry,
even though it works entering from another terminal. `cursorUpdate` alone has
the same entry gap, which is why the cursor must **also** be set in
`mouseEntered` (which does fire on that entry). The split divider follows this
same pattern: its grab strip is the AppKit `SplitterHandleView`
(`SplitContainerView`), which sets the resize cursor in both `cursorUpdate` and
`mouseEntered`. A SwiftUI **`.pointerStyle`** does not work here: it loses the
cursor to the terminal surface's own `cursorUpdate` (the terminal is a concrete
sibling `NSView`), so a concrete overlay `NSView` is required here too.

**How to apply:** mirror `GhosttySurfaceView`'s `mouseEntered`/`cursorUpdate`/
`mouseExited` cursor trio for any new overlay/handle over a terminal surface;
drive the shape with a small state flag (e.g. `isTracking` for open vs closed
hand). See [[ghostty-is-the-reference]].
