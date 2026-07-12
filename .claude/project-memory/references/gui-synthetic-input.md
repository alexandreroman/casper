---
name: "Driving the Casper GUI with synthetic mouse input"
description: "The debug channel has no mouse verb; drive CGEvent mouse events to verify pointer interactions, but the window must be key first"
type: reference
---

# Driving the Casper GUI with synthetic mouse input

The `debug-casper` debug channel exposes only text/observation verbs
(`dump-state`, `read-text`, `send-text`, `screenshot`) — **no mouse verb**. To
verify pointer-driven interactions (divider drag-resize, pane drag-relocate,
hover cursors) drive **`CGEvent` mouse events** (`.leftMouseDown` /
`.leftMouseDragged` / `.leftMouseUp` / `.mouseMoved`, posted to `.cghidEventTap`)
from a small throwaway Swift script.

**Why:** these interactions can only be exercised through real pointer events;
without this you cannot confirm them end-to-end in the running app.

**How to access:**

- **Window must be key or events are silently dropped.** `NSRunningApplication
  .activate()` alone is not enough — first synthesize a click on the toolbar/title
  bar (e.g. global `(windowX + N, windowY + 30)`) to make the window key, then
  post the real gesture in the **same** process so focus is held. Skipping this
  makes drags no-op unpredictably (looks like an app bug; it is not).
- **Global screen coordinates.** Get the window frame (top-left origin, points)
  from `CGWindowListCopyWindowInfo` (owner name contains "casper", layer 0). The
  `screenshot` PNG is the window backing at 2×, so `global = windowOrigin +
  backingPixel/2`.
- **Park the cursor off-window before a screenshot/scan.** The capture includes
  the cursor; a parked cursor inside the frame corrupts pixel measurements (e.g. a
  luminance scan for the 1pt separator line locks onto the bright cursor glyph
  instead). Move it far off-window first.
- **Divider geometry:** the resize hit strip is 18pt centred on the line — the
  transparent AppKit `SplitterHandleView` in `SplitContainerView`; the pane
  drag-grip (`PaneDragHandleView`) is a 200×24pt rect at each pane's top edge only
  — mid-height off-centre points hit neither.
- **Side effects persist.** Pane drag-relocate writes the new layout to
  `session.json` (unlike divider ratios, which are local `@State`); restore the
  user's `session.json` if a stray test drag reorganises their panes.

Related: [[debug-screenshot-screencapturekit]], [[terminal-overlay-cursor]],
[[ghostty-is-the-reference]].
