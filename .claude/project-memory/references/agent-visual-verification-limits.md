---
name: "Agents cannot self-verify SwiftUI visual changes"
description: "Task/Agent subagents lack screen-recording (TCC) permission even when the interactive session's terminal has it, so toolbar/UI styling changes need human-provided screenshots, not agent self-verification"
type: feedback
---

# Agents cannot self-verify SwiftUI visual changes

Subagents dispatched via the Agent tool consistently report
`SCScreenshotManager`/`ScreenCaptureKit` failing with "The user declined TCCs
for application, window, display capture" when attempting
`casper debug screenshot`, even on a machine where the interactive session's own
terminal can capture successfully. This reproduces across independent subagent
dispatches.

**Why:** screen-recording permission (see [[debug-screenshot-screencapturekit]])
is granted per requesting process/TCC identity, not inherited by whatever spawns
a subagent — a subagent's sandbox does not carry the interactive terminal's
grant.

**How to apply:** for any visual/styling change (toolbar chrome, SwiftUI layout,
colors, icons), don't ask an implementer subagent to screenshot-verify its own
work — it will reliably fail and burn a turn. Have the subagent build +
`make build`/compile-verify only, then let the **interactive session** (which
can call the debug-casper screenshot tooling, or more simply the user's own eyes
via `make dev`) do the actual visual check. Expect visual polish to be an
iterative loop driven by the user's screenshots, not something an agent confirms
end-to-end alone.

**Offscreen rendering is a different mechanism and does work.** Pure AppKit
drawing can be pixel-verified from any agent context without a screen-recording
grant, because nothing captures the screen: render the view into
`bitmapImageRepForCachingDisplay(in:)` via `cacheDisplay(in:to:)`, then read
`NSBitmapImageRep.colorAt(x:y:)`. The rep comes back at the backing scale, so
pixel coordinates are 2× points on a Retina display. `DiffChromeTests` uses this
to assert the diff view's row tints, gutter stripe and line-number colors, which
`DiffTextView` and `DiffGutterRuler` draw in `drawBackground(in:)` and
`drawHashMarksAndLabels(in:)`. This covers **drawing code**, not composited
SwiftUI hierarchies or window chrome — the limits below still hold for those.

**Capture the composed container, not each view on its own.** A capture taken
from one view's bounds shows only what that view painted inside them, so a whole
class of defect is invisible to it: one view painting *over* another. A ruler
that fills past its column wipes the code beside it on screen while every
per-view assertion stays green, because the escaping fill never reaches the text
view's own bitmap (see [[nsrulerview-unclipped-drawing]]). Compose what the
reader actually sees — `cacheDisplay` the scroll view, or a wrapper holding the
surface under a stand-in for the chrome above it — and assert there. Two
captures of the same wrapper, one before the surface is added and one after,
compare cleanly pixel for pixel; an absolute color literal does not, because
`NSBitmapImageRep` returns colors in its own space and a literal put through
that conversion no longer matches itself.

**Probe a partial dirty rect, not only the full bounds.** `cacheDisplay(in:to:)`
accepts any sub-rect of the view and passes it through as the dirty rect, and
that is the only way to distinguish the two halves of a coordinate conversion in
a view that both *queries* geometry by the dirty rect and *fills* into view
space. Over a full-bounds rect the queried set is the same whether or not the
query converts, so a conversion missing on the query side alone reads as green.
In production the dirty rect is the strip a scroll just exposed, and there the
same code drops the rows straddling that strip's top edge on every frame. Sample
a row that straddles the sub-rect's top edge: it must be drawn whole, because
the fill covers the row's full height and the context clips the overflow.

**Do not assume the interactive session can always capture either.** In some
session configurations even the main-loop `Bash` tool's shell lacks the
screen-recording grant: `screencapture -x` fails with `could not create image
from display`, and `casper debug screenshot` needs both a running instance *and*
a loaded workspace surface (a fresh `--session` instance has none →
`{"error":"no surface"}`, and that verb captures the terminal surface, not the
window's title-bar/toolbar chrome anyway). Net: title-bar/toolbar visuals often
cannot be pixel-verified from within any agent context — rely on the
compile-clean build plus the shared-code guarantee (e.g. one common view
modifier applied to every chip makes them identical by construction), and defer
the final visual sign-off to the user viewing `make dev`.
