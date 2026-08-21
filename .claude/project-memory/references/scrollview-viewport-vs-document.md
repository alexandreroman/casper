---
name: "A ScrollView's padding and height are viewport-side"
description: "Padding around a SwiftUI ScrollView pads the viewport, not the scrolled document, and a pinned height overflows a shorter host"
type: reference
---

# A ScrollView's padding and height are viewport-side

Two independent facts about a SwiftUI `ScrollView`, measured on
`WorkspaceInfoPanel` hosted in a real `NSWindow` (a window is required —
without one the document view never lays out, so every geometry read answers
against an unresolved tree):

- **`.padding(_:)` applied outside a `ScrollView` pads the viewport, never the
  document.** A document whose content ends flush with its own bottom therefore
  puts its last line exactly on the viewport's bottom edge at maximum scroll,
  where sub-point rounding clips it and the tail reads as truncated.
  Trailing slack has to live *inside* the scrolled content —
  `WorkspaceInfoPanel.contentBottomInset`, applied to the content and not
  folded into the `ScrollView`'s own height, so a message that already fits
  keeps hugging its text instead of gaining an empty band under one line.
- **`.frame(height:)` on a `ScrollView` is a pin, and a pin overflows.** When
  the host offers less room than the pinned height, the viewport's bottom hangs
  outside the host and the points hanging out are unreachable at every scroll
  offset — measured linear: a 420 pt viewport in a 380 pt host loses 40 pt, in
  a 200 pt host 220 pt. `.frame(idealHeight: h, maxHeight: h)` keeps the same
  hug-to-content and cap behaviour while yielding to a shorter host.

`WorkspaceInfoPanelTests` pins both.
`testLastLineKeepsATrailingMarginAtMaximumScroll` scrolls to the maximum offset
and compares the last layout fragment's `maxY` (converted out of text-container
coordinates through `textContainerOrigin`) against the clip view's bottom.
`testShortHostStillReachesTheEndOfTheMessage` checks that the maximum offset
plus the *visible* part of the clip view reaches the document's full height.
