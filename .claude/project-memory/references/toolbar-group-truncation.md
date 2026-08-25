---
name: "A toolbar group must be told to truncate"
description: "SwiftUI wraps an unbounded Text mid-word when a toolbar group is proposed less than its ideal width; lineLimit(1) is the only thing that stops it"
type: reference
---

# A toolbar group must be told to truncate

A `ToolbarItem` whose content carries no line limit **wraps** — mid-word,
even — as soon as the toolbar proposes it less width than its ideal, pushing
the title bar open instead of shortening its text. Both
`Sources/CasperUI/WorkspaceTitleLabel.swift` and the leading
`ToolbarItem(placement: .navigation)` group in
`Sources/CasperUI/WorkspaceDetailView.swift` carry `.lineLimit(1)` for this
reason; the diff badge's `+N`/`−N` are single "words" that stack the same way.

**Why:** the toolbar hands out the leftover width silently. A ~900pt window with
the sidebar open and the trailing chips (Merge, Run script, Editor, Inspector)
placed left the leading group under ~200pt in the reported case, and the wrap
happens with no warning, no clipping, and no compile-time signal.

**How to access:** the geometry is measurable headlessly —
`Tests/CasperUITests/WorkspaceTitleLabelTests.swift` hosts the label at a sweep
of hostile widths (220 down to 40pt) and asserts its height never leaves the
one-line baseline. Removing `.lineLimit(1)` moves those heights to
32/64/112/304, so the assertion has teeth (see
[[headless-swiftui-layout-tests]]).

Graceful degradation below the fix: wrap the candidates in
`ViewThatFits(in: .horizontal)` ordered widest-first, so *context* (the Space
name) is dropped whole rather than truncated to an ellipsis stub while
*identity* (the branch) survives and middle-truncates only as a last resort.
