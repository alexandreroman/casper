---
name: "NSTextBlock/NSTextTable borders are unreliable"
description: "A bare NSTextBlock border with both width and color set drew nothing in the info panel; the fix avoids that whole AppKit feature family rather than trusting it"
type: feedback
---

# NSTextBlock/NSTextTable borders are unreliable

`MarkdownAttributedString`'s block quote rule and thematic-break rule both
used a bare `NSTextBlock` with a border width and color set on one edge
(`setWidth(_:type:for:edge:)` + `setBorderColor(_:for:)`) — the configuration
Apple's own docs say is required. Both drew nothing in the running app: the
block quote showed no leading bar, the thematic break showed only its
reserved vertical spacing with no line in it.

**Why:** `NSTextBlock`/`NSTextTable` border rendering has multiple open,
Apple-acknowledged AppKit bugs independent of this app's code — e.g.
FB16391696 (table borders intermittently fail to draw, traced to a *margin*
set on the block) and FB15162186 (`NSTextList` not rendering on macOS at
all, a WWDC22-announced feature). This is a known-fragile corner of AppKit,
not something a single missing attribute explains.

**Headless pixel verification cannot settle this either way.** An offscreen
`cacheDisplay(in:to:)` render (see
[[agent-visual-verification-limits]]) of the GFM table — the one construct
already confirmed visibly correct on screen via a human screenshot — produced
no detectable border pixels either, under several independent detection
methods (grid dump, longest-run-per-column, exact-color-match diffing against
a border-off baseline). The offscreen technique that works for a view's own
`drawBackground(in:)`/`drawHashMarksAndLabels(in:)` overrides (`DiffChromeTests`)
does not reach whatever internal path draws `NSTextBlock`/`NSTextTable`
borders — it cannot distinguish "broken" from "not observable this way" for
anything in this family.

**How to apply:** don't add a new bare `NSTextBlock`/`NSTextTable` border and
trust it renders, and don't try to headlessly pixel-prove one either way.
- For a chrome element that doesn't need to be an actual multi-cell table
  (like a rule), prefer a technique from a different, well-supported drawing
  path — `renderThematicBreak` rasterizes the rule into an `NSImage` and
  embeds it via an `NSTextAttachment`, which composites like any inline
  image instead of relying on block/table border compositing. A second path
  was also tried and is equally dead: a `.thick` `.underlineStyle` on a tab
  run stretched by a far-out tab stop drew nothing either, leaving only the
  reserved line height as a tall blank gap — underlining a tab's whitespace
  advance is evidently not a drawn glyph the way underlining actual text is.
  Both the bare-border and the underline-on-a-tab-run path are dead ends;
  the attachment technique above is the one that works.
- Where a border is unavoidable (the GFM table itself has no substitute),
  keep it working by following the one finding with a concrete trigger:
  avoid setting a *margin* on the block/cell (FB16391696's traced cause).
  `renderTableCell`'s un-nested case already does this by construction;
  `blockQuoteRule` was rewritten to a private 1x1 `NSTextTable` cell
  (reusing the same `NSTextTableBlock` the GFM table's cells use) with no
  margin set, on the reasoning that this narrows the exposure to the known
  bug even though it can't be headlessly proven.
- Either way, final confirmation that the pixels actually appear is a
  human's, via `make dev` — an attribute (`textBlocks`, `.underlineStyle`,
  a border color) is not a pixel.
