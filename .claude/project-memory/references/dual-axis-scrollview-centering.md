---
name: "Dual-axis ScrollView centers undersized content"
description: "A SwiftUI ScrollView with both axes vertically centers content smaller than its viewport; anchor it to .top"
type: reference
---

# Dual-axis ScrollView centers undersized content

A SwiftUI `ScrollView([.vertical, .horizontal])` (both axes) vertically CENTERS
its content when the content is smaller than the viewport, instead of
top-aligning it. A `.frame(maxHeight: .infinity, alignment: .top)` on the
ScrollView does NOT fix this — it does not affect the internal content
positioning.

**Why:** This is the reason short diffs in the inspector's `DiffSurfaceView`
floated in the vertical middle. Single-axis scroll views top-align by default,
so this only bites when both axes are enabled (needed here for horizontal
scrolling of long, non-wrapped diff lines).

**How to fix:** Add `.defaultScrollAnchor(.top)` on the ScrollView (macOS 14+).
It directly controls where undersized content rests, so a short diff anchors to
the top while taller content keeps its intrinsic size and still scrolls — no
manual height pinning needed. Prefer this over the older workaround of measuring
the viewport height with a `GeometryReader` and pinning the inner content to
`minHeight: contentHeight`; that pin let the horizontal scrollbar steal a strip
of height and made a short diff report a spurious vertical scrollbar. See
[DiffSurfaceView.swift](../../../Sources/CasperUI/DiffSurfaceView.swift).

**Do not toggle the axes across renders:** dynamically switching a ScrollView's
`axes` parameter (e.g. `.horizontal` vs `[.vertical, .horizontal]`) between
renders is unreliable for scroller visibility on macOS — a horizontal scrollbar
may fail to show. Always pass a constant axis set and control positioning with
`.defaultScrollAnchor(.top)` instead.
