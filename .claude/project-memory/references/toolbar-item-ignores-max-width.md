---
name: "A toolbar item ignores `.frame(maxWidth:)`"
description: "A ToolbarItem's content is measured under an unspecified proposal, so a flexible maxWidth frame constrains nothing and a ViewThatFits behind it always picks its widest candidate; a single-subview Layout is what imposes a width budget"
type: reference
---

# A toolbar item ignores `.frame(maxWidth:)`

SwiftUI measures a `ToolbarItem`'s content under an **unspecified** proposal,
and a flexible `.frame(maxWidth: budget)` answers such a proposal by proposing
nothing downward. A `ViewThatFits` behind that frame therefore always picks its
**widest** candidate, whatever the budget says. Measured directly: candidates
of 300 / 200 / 100 pt behind `.frame(maxWidth: 199)` still select the 300 pt
one.

**Why:** the failure is silent. The frame compiles, renders, and clamps nothing,
so a width-budget ladder reads as "the budget is never tight" rather than as a
broken constraint — and the symptom shows up somewhere else entirely, as AppKit
overflowing the item into its chevron popover.

**How to access:** what works instead is a container with a **definite** width,
which proposes that width downward: the title bar's row in
`Sources/CasperUI/WorkspaceDetailView.swift` gets one from
`.frame(width: rowWidth)`, and the chips' `ViewThatFits` steps down its
candidates as that width falls, with no intermediate layout of any kind between
the two. `Tests/CasperUITests/WorkspaceToolbarActionsTests.swift` pins the
selected candidate at a sweep of widths, including the floor where only the
narrowest one is left.

Related: [[toolbar-overflows-before-squeezing]], [[toolbar-group-truncation]],
[[headless-swiftui-layout-tests]].
