---
name: "A toolbar group must be told to truncate"
description: "SwiftUI wraps an unbounded Text mid-word when a toolbar group is proposed less than its ideal width; lineLimit(1) is the only thing that stops it"
type: reference
---

# A toolbar group must be told to truncate

A `ToolbarItem` whose content carries no line limit **wraps** — mid-word,
even — as soon as it is proposed less width than its ideal, pushing the title
bar open instead of shortening its text. Every title-bar control lives in a
single `ToolbarItem(placement: .navigation)` in
`Sources/CasperUI/WorkspaceDetailView.swift` — title, info chip, diff badge,
Merge, Run Script, Editor and the inspector selector — and the line limit is
applied inside it, in `Sources/CasperUI/WorkspaceTitleBar.swift`, on the
title/info group and on every chip row, alongside the one in
`Sources/CasperUI/WorkspaceTitleLabel.swift`. The diff badge's `+N`/`−N`
are single "words" that stack the same way.

**Why:** width is handed out silently, and a `Text` given less than it wants
answers by wrapping — no warning, no clipping, no compile-time signal. The
one-item title bar is itself a consequence of how AppKit hands out that width:
it overflows a toolbar item whole rather than proposing it less — see
[[toolbar-overflows-before-squeezing]].

**How to access:** the geometry is measurable headlessly —
`Tests/CasperUITests/WorkspaceTitleLabelTests.swift` hosts the label at a sweep
of hostile widths (220 down to 40pt) and asserts its height never leaves the
one-line baseline. Removing `.lineLimit(1)` moves those heights to
32/64/112/304, so the assertion has teeth (see
[[headless-swiftui-layout-tests]]).

Graceful degradation under the line limit: *context* (the Space name) is
dropped whole by the row's single ladder (`WorkspaceTitleBarRow`), never by the
label, rather than truncated to an ellipsis stub, while *identity* (the branch)
survives and middle-truncates only as a last resort.
