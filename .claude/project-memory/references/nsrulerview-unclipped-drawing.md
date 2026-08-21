---
name: "NSRulerView draws outside its own bounds"
description: "AppKit calls a ruler's draw with rects far larger than the ruler — one pass with an infinite rect and clip — and does not clip its drawing to its bounds, so a custom ruler must clip to bounds itself in draw(_:)"
type: reference
---

# NSRulerView draws outside its own bounds

A custom `NSRulerView` is handed dirty rects that reach far outside its own
column, and its drawing is **not** clipped to its bounds. Anything it paints
lands wherever it is aimed, over its siblings in the scroll view and outside the
scroll view entirely. Measured on `DiffGutterRuler`, a 42 pt-wide vertical ruler
in a 500 pt-wide scroll view:

- One draw pass arrives with `rect` **and** the context's clip set to the whole
  coordinate plane (`±8.988465674311579e307`, i.e.
  `±CGFloat.greatestFiniteMagnitude / 2`).
- Another arrives with the scroll view's whole content area:
  `(0, -40, 500, 340)` against `bounds` of `(0, 0, 42, 300)` — wider than the
  column, and starting above its top edge by the text view's
  `textContainerInset`.
- `wantsDefaultClipping` is `true` throughout and does not confine any of it.

Three distinct paints escape as a result: a background fill of the passed rect
covers the code column the clip view already drew; per-row chrome placed from
scroll-relative geometry rides above the ruler's top edge, because rows above
the viewport still fall inside the passed rect; and `NSRulerView`'s own chrome —
a hairline down the ruler's trailing edge — runs the full height of the infinite
clip.

**Why:** the third one is drawn by no method of the subclass, so confining
paints one at a time inside `drawHashMarksAndLabels(in:)` cannot reach it. Only
a clip that wraps `super` covers all three, and it holds for chrome added later
without anyone remembering the rule.

**How to apply:** in any `NSRulerView` subclass, override `draw(_:)` to
`saveGraphicsState()`, `bounds.clip()`, call `super.draw(_:)`, then restore.
Treat the rect passed to `drawHashMarksAndLabels(in:)` as a *work-scoping hint*
only — intersect it with `bounds` before deriving geometry queries from it — and
never as a boundary. Assertions live in `DiffChromeTests`; per-view captures
cannot see any of this, so they compose the scroll view (see
[[agent-visual-verification-limits]]). Related geometry facts in
[[textkit2-layout-geometry]].
