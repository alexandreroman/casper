---
name: "TextKit 2 layout geometry gotchas"
description: "Measured facts about NSTextLayoutManager fragment geometry and layout cost that the diff renderer's per-line chrome depends on"
type: reference
---

# TextKit 2 layout geometry gotchas

Facts measured in-process with the Xcode 26 toolchain, on an `NSTextView` at a
400 pt width holding a `DiffDocument` of 200 files × 100 addition lines
(20 200 paragraphs, 351 372 pt tall), for anything reading
`NSTextLayoutManager` geometry.

## Shape

- **Reading `NSTextView.layoutManager` migrates the view to the TextKit 1
  stack** and leaves `textLayoutManager` nil. Force layout through
  `textLayoutManager.ensureLayout(for:)`, never through the compatibility
  `NSLayoutManager`. No assertion catches this — a migrated view still answers
  every call, just from the other stack — so
  `DiffFragmentGeometryTests.makeTextView` carries the reason in a comment.
- A plain `NSTextView(frame:)` **is** TextKit 2 backed (`textLayoutManager` is a
  non-nil `NSTextLayoutManager`), so a headless geometry test needs no manual
  `NSTextContentStorage` → `NSTextLayoutManager` → `NSTextContainer` chain.
- **`paragraphSpacingBefore` is folded into `layoutFragmentFrame` and pushes the
  first line fragment down by it.** A paragraph carrying 45 pt of spacing before
  a 12 pt row reports `frame.height == 57` with the first `textLineFragments`
  entry at `typographicBounds.minY == 45`. What downstream arithmetic should
  rest on is the equality — that offset **is** the spacing the style asked,
  so a band's top is `frame.minY + firstRow.typographicBounds.minY - band`,
  never `frame.minY - band`. `DiffTextAssemblyTests`
  `testFilesAfterTheFirstReserveTheStickyHeaderBand` pins the spacing that goes
  in; `DiffFragmentGeometryTests`
  `testFileOwnershipStartsAtTheReservedBandNotAtTheLayoutFragment` and
  `testFirstFilesBandTopSitsAboveTheContainerOrigin` pin the geometry that comes
  out.
- TextKit **ignores `paragraphSpacingBefore` on the document's first
  paragraph**, so its first row sits at `typographicBounds.minY == 0` and the
  same formula yields a *negative* band top. Space reserved ahead of it has
  to come from `NSTextView.textContainerInset` instead, which lies above the
  container's origin.
- **The last paragraph carries an extra, characterless line fragment** — the
  caret position after the document's final `"\n"` — as a second entry in the
  same layout fragment's `textLineFragments` (`characterRange.length == 0`).
  There is no extra *layout* fragment past the last paragraph. Per-row chrome
  must skip that entry or it paints one phantom row per document;
  `DiffFragmentGeometryTests.testEveryVisibleFragmentMapsToADiffLine` catches it
  by counting rows against the document's own lines.
- `NSTextLineFragment.typographicBounds` is relative to the owning layout
  fragment's origin; offset by `layoutFragmentFrame.origin` for container
  coordinates.
- Layout-manager geometry is in **text-container** coordinates. A text view
  shifts that by its `textContainerOrigin`, and the container's own
  `lineFragmentPadding` (5 pt by default) shows up in `frame.minX`. The layout
  manager cannot convert — only the text view knows where its container sits —
  so a caller holding view coordinates converts on the way in and out.
  `textContainerOrigin` is the property to read: it folds `textContainerInset`
  together with any centering AppKit applies when the container is narrower than
  the view, so the two coincide only while that centering is zero.
- **A ruler's own chrome leaves no divider.** An `NSRulerView` whose
  `drawHashMarksAndLabels(in:)` fills the passed rect itself paints nothing of
  its own over it — measured on the ruler's trailing pixel column, which carries
  whatever the override drew there (`DiffChromeTests`
  `testTheGuttersTrailingEdgeCarriesTheRowTintAndNoDivider` pins it).

## Cost

Layout is incremental and strictly forward from the container's origin, which
decides what is cheap:

- **`enumerateTextLayoutFragments` is genuinely bounded** when the callback
  stops at the first fragment past the rect. Over a 300 pt rect on a cold layout
  manager it leaves `usageBoundsForTextContainer.height` at 318, against 351 372
  for the whole document.
- **`textLayoutFragment(for: CGPoint)` is O(scroll offset)**, not O(rect): 0.005
  ms at `y = 100` against 1.17 ms near the bottom. It is a forward scan, so a
  per-frame draw pays for its own depth in the document.
- **`textLayoutFragment(for: NSTextLocation)` is ~0.004 ms wherever it points**,
  and returns a fragment whose `state` says whether the geometry is real
  (`.layoutAvailable`) or estimated. Probing it and checking `state` is the way
  to get a laid-out frame without forcing layout.
- **`ensureLayout(for:)` costs its whole range even where the range is already
  laid out**: 0.073 ms to the second file, 11.0 ms to the last. A range starting
  at `documentRange.location` is therefore linear in how deep the target sits,
  which makes such a call unaffordable on a per-scroll-notification path and
  fine on a one-per-jump path.
- On a cold manager, reaching the last file's first paragraph lays out 99.5% of
  the document's height, because everything above it has to be laid out first.
  "Stop at the target's first paragraph" saves the target's *body*, no more.
