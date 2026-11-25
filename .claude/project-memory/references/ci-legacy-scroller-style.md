---
name: "CI runners use the legacy scroller style, settled late"
description: "No trackpad on CI: legacy scrollers narrow the clip view, and the first scroll view in a process flips to legacy a turn late"
type: reference
---

# CI runners use the legacy scroller style, settled late

Measured on the GitHub Actions macOS 15 and 26 runners (November 2026).

- **The runners have no trackpad**, so `NSScroller.preferredScrollerStyle` is
  `.legacy`. A legacy vertical scroller takes width from the clip view: the
  diff surface's clip is 765 pt (macOS 15) or 763 pt (macOS 26) wide on CI,
  against 780 pt under the overlay style a trackpad Mac uses.
- **The style settles after the first scroll view exists.** In a fresh
  process, the first scroll view is created under `.overlay` and flips to
  `.legacy` one run-loop turn later. Only the first surface a test process
  mounts sees the flip, so a test that is flaky only when it runs first in
  the process points here.
- **Any clip-width change discards TextKit 2's layout.** The narrower text
  container invalidates layout: the fragment under the viewport drops to
  state `.none`, and point probes (`textLayoutFragment(for: CGPoint)`,
  `DiffFragmentGeometry.fileIndex(atY:)`) resolve against estimated heights,
  which can name the next file. The clip view's `bounds.origin.y` does not
  move. See [[textkit2-layout-geometry]].
- **A held diff scroll target lands after the scroller settles.**
  `DiffTextSurface.Coordinator.viewportDidChange()` lays the text view out
  and re-tiles before resolving the file's top: the container's tile runs
  before the text view grows, so it hides the auto-hiding scroller, and a
  legacy scroller the grown document calls for would rewrap the text under a
  scroll that has already landed. See [[diff-surface-data-flow]].
- **Reproducing locally** takes `scrollView.scrollerStyle = .legacy` forced
  in the test (as in
  `DiffTextSurfaceTests.testAHeldScrollLandsOnItsFileWhenTheDocumentCallsForALegacyScroller`);
  a trackpad Mac never shows these failures otherwise. A test asserting where
  the clip view sits reads it after `ensureLayout(for: documentRange)`, as
  `DiffSurfaceViewScrollTests.fileAtViewportTop` does.
