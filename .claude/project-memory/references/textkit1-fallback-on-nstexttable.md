---
name: "An NSTextTable drops an NSTextView back to TextKit 1"
description: "A view built explicitly on TextKit 2 migrates itself to TextKit 1 once its storage holds an NSTextTable, and the two engines lay the same string out to different heights"
type: reference
---

# An NSTextTable drops an NSTextView back to TextKit 1

Building the stack by hand — `NSTextContentStorage` → `NSTextLayoutManager` →
`NSTextContainer`, passed to `NSTextView(frame:textContainer:)` — asks for
TextKit 2 but does not **keep** the view there. When the storage contains an
`NSTextTable`, which is how `MarkdownAttributedString` renders a GFM table,
AppKit migrates the view to the TextKit 1 stack **by itself, on a display
pass**, with no call from app code involved: `textLayoutManager` goes nil and
every later geometry read answers from `NSLayoutManager`. Measured in
`WorkspaceInfoPanel`, the migration lands on the panel's first display pass, and
in the running app roughly 14 ms after the popover appears. The same message
with its `|` table rows removed stays on TextKit 2 for its whole life, so the
`NSTextTable` is the trigger.

**The two engines lay the same string out to different heights**, and the sign
of the difference depends on the content, so neither is a safe proxy for the
other. Measured at a 496 pt content width on macOS 26, TextKit 2 first:

- table cells long enough to wrap: 1461 → **1797** pt (six tables), 226 → 282 pt
  (one);
- a table of short cells: 2179 → 1603 pt, and 1980 → 780 pt for five narrow
  columns.

**The height gap is a table-cell phenomenon; the migration is not.** A block
quote carries an `NSTextBlock` too — `blockQuoteRule()` renders it as a 1x1
`NSTextTable` cell — and it migrates the view exactly like a table does, yet
both engines lay it out to the *same* height: measured identical across seven
quote shapes (one wrapping line, two paragraphs, quote + list, nested quote,
quote after a heading, quote then paragraph, quote + code — 136/136, 125/125,
108/108, 82/82, 76/76, 60/60 pt). So a test that means to discriminate the two
engines needs a table of **wrapping** cells; a quote fixture asserts nothing
about height, and what it can pin instead is the migration itself plus the
`textBlocks` attribute the engine prediction keys on.

**So a caller must not measure a message on one stack and pin a frame from it.**
An `NSTextView` whose frame falls short of what its live engine laid out clips
the overflowing lines against its own bounds — they are drawn at no scroll
offset, because the enclosing scroll view's document is sized from that same
short frame. `MarkdownTextView` therefore reports the height it has really laid
out from `LinkCursorTextView.layout()`, and `WorkspaceInfoPanel` sizes the view
from `max(measured, reported)`: both numbers are lower bounds on what has to be
drawn, and a frame that is too tall costs only invisible scroll slack while one
that is too short eats lines. `height(for:width:)` remains the opening height,
so the first pass is not a zero-height one.

**The opening measurement predicts the engine rather than assuming one.** An
`NSPopover` freezes its content size at the panel's first layout pass, so a
height the live view reports one main-queue hop later grows the scrolled
document while the viewport stays put — the tail of the message then sits
outside the popover, reachable only by scrolling.
`MarkdownTextView.measuredHeight(of:width:)` therefore scans the rendered
string for a paragraph style carrying `textBlocks` — the measured migration
trigger, covering both a GFM table's cells and the block quote's rule — and
measures such content on a throwaway TextKit 1 stack (`NSTextStorage` →
`NSLayoutManager` → `NSTextContainer`, `ensureLayout(for:)` then
`usedRect(for:)`, the very pair `reportLaidOutHeight()` uses) and everything
else on TextKit 2. The scan sits beside the render, in the cache keyed by
`(markdown, width, appearance)`, so it costs one pass per message rather than
one per SwiftUI `body`. Deliberately not `max(textKit1, textKit2)`: the sign
of the gap depends on the content, so the larger of the two opens the popover
with a wide empty band under a short-celled table. `max(measured, reported)`
is the safety net that keeps the scrolled document complete when a prediction
is wrong.

**Reading the live engine has to branch on `textLayoutManager != nil` first.**
Merely reading `NSTextView.layoutManager` performs the very migration in
question (see [[textkit2-layout-geometry]]), so a fallback chain that starts
from TextKit 1 causes what it means to detect. TextKit 2 answers
`ensureLayout(for: documentRange)` then `usageBoundsForTextContainer`; TextKit 1
answers `ensureLayout(for: container)` then `usedRect(for:)`.

That same property makes the migration reachable **deterministically in a
test**: reading `layoutManager` puts the view on TextKit 1 synchronously, with
no display pass to race.
`WorkspaceInfoPanelTests.testATableMessageIsSizedByTheEngineThatLaysItOut`
does that and then asserts the frame covers `usedRect`, against a fixture of
wrapping table cells where TextKit 1 is the taller of the two.

Narrows [[nstextview-caller-sized-frame]]: a caller-sized `NSTextView` still
must not resize itself, and the size the caller hands it comes from the view's
own layout rather than from a measurement taken elsewhere.
