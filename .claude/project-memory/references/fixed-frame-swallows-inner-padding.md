---
name: "Fixed frame swallows inner padding"
description: "SwiftUI .frame(width:) reports its explicit size to the parent regardless of what padding inside it would otherwise add"
type: reference
---

# Fixed frame swallows inner padding

`.frame(width: X)` fixes the size a SwiftUI view REPORTS to its parent container
(an `HStack`, for instance) to exactly `X`, regardless of any padding or other
content nested inside that frame. A `.padding(...)` applied *before*
(structurally inside) a `.frame(width:)` in the modifier chain contributes
nothing to the parent's layout math — confirmed empirically via an
`NSHostingView` fitting-size probe, which reports exactly the frame's width,
never more, no matter what padding sits inside it.

To make a value actually widen what a parent lays out around, either put the
padding *outside* (structurally after) the `.frame(width:)`, or bake the value
into the frame's own width. `WorkspaceInfoButton`
(`Sources/CasperUI/WorkspaceInfoButton.swift`) uses the latter: the collapsed
(no-message) state's separation from its neighbour comes from `collapsedWidth`
being the `.frame(width:)` target itself, not from the trailing padding still
living inside that frame.
