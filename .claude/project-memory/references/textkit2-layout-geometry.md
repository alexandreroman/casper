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
- **A paragraph's style comes from its first character, and a paragraph ends at
  a newline** — not at an attribute-run boundary. So the `"\n"` joining two
  blocks belongs to the *preceding* block's paragraph, and any
  `NSParagraphStyle` set on that newline alone is never read: measured at 0 pt
  realized against 12 pt of `paragraphSpacing` asked for. A gap that has to
  land between two specific paragraphs needs a paragraph of its own —
  newline-delimited on both sides, with `minimumLineHeight ==
  maximumLineHeight` fixing its height and a 1 pt font so the metrics
  underneath don't fight that height (`MarkdownAttributedString`'s
  `Builder.separator`).
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
- **A hosted `NSTextView` lays the whole document out at its layout pass.** With
  `isVerticallyResizable` it has to know its own height, so `layout()` forces
  full layout — measured at 57 861 pt for a 3 002-paragraph document — however
  little the viewport shows. What stays lazy is the window between a text-storage
  swap and the layout pass after it: `setAttributedString` leaves the whole
  document cold, and every bounds-change notification until the next frame reads
  a cold manager. A diff recomputed on each file change sits in that window
  constantly, so a per-notification reader takes the non-forcing
  `DiffFragmentGeometry.warmTop(ofFileAt:)` and treats a file with no geometry as
  off-screen; the refresh path warms the viewport once with
  `ensureLayout(in:)` so the chrome has bands to find before anything draws.
- **A position read before layout settles is provisional.** A fragment's frame
  rests on the *estimated* heights of everything the real layout has not
  reached, so the layout pass that replaces those estimates moves it —
  measured at 90.65 pt for a file two screens into a six-file document of
  wrapping lines, read right after a text-storage swap. Chrome reading geometry
  inside its own `draw` follows the text there for free; chrome that **caches**
  a position needs an invalidation hook on the layout pass itself
  (`NSTextView.layout()`, after `super`, is where TextKit 2 lays the viewport
  out), or it holds the estimate until the next scroll notification. That hook
  wants coalescing: a diff refresh invalidates layout once per storage swap and
  once per highlight painted into it, and only the last pass of the burst
  carries settled geometry.
- **The estimates themselves are macOS-version-specific.** The same cold document
  answers with a different total height on macOS 15 than on macOS 26 — measured
  87 910 pt against 77 243 pt for one 906-paragraph diff of wrapping lines, from
  an *identical* pre-swap real layout. So a container `y` maps to a different
  part of the document depending on the OS: the same viewport top edge drew
  lines 541–548 on macOS 15 and 598–605 on macOS 26. Real, forced layout agrees
  everywhere; only the estimated regime diverges, which is why anything holding
  an absolute `y` across a storage swap is holding a platform-dependent number.
