---
name: "Dual-axis ScrollView centers undersized content"
description: "A SwiftUI ScrollView with both axes vertically centers content smaller than its viewport; pin it top-leading"
type: reference
---

# Dual-axis ScrollView centers undersized content

A SwiftUI `ScrollView([.vertical, .horizontal])` (both axes) vertically CENTERS
its content when the content is smaller than the viewport, instead of
top-aligning it. A `.frame(maxHeight: .infinity, alignment: .top)` on the
ScrollView does NOT fix this — it does not affect the internal content
positioning.

**Why:** This is the reason short diffs in the inspector's `DiffSurfaceView`
floated in the vertical middle. Single-axis scroll views top-align by default, so
this only bites when both axes are enabled (needed here for horizontal scrolling
of long, non-wrapped diff lines).

**How to access:** Fix by measuring the viewport size with a `GeometryReader`
(store width AND height in `@State`) and pinning the scroll content to at least
that size, top-leading:
`.frame(minWidth: contentWidth, minHeight: contentHeight, alignment: .topLeading)`
on the inner `LazyVStack`. Short content then fills the viewport and anchors to
the top; taller content keeps its intrinsic size and still scrolls. See
[DiffSurfaceView.swift](../../../Sources/CasperUI/DiffSurfaceView.swift).
