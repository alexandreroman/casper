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
applied inside it, on the title/info group and on every chip row, alongside the
one in `Sources/CasperUI/WorkspaceTitleLabel.swift`. The diff badge's `+N`/`−N`
are single "words" that stack the same way.

**Why:** width is handed out silently, and a `Text` given less than it wants
answers by wrapping — no warning, no clipping, no compile-time signal. The one
item is itself a consequence of that: AppKit sizes a `ToolbarItem`'s hosted view
to its content's **ideal** width and will not shrink it below that, so a bar too
narrow overflows the item whole into the chevron rather than proposing it less.
Measured on the running app at a 600 pt window, where the navigation item alone
reported 293 pt and went into the chevron with its title still one truncatable
line — and in the chevron the custom chips lose their capsule chrome and the
segmented control clips to a lone glyph. Hence one item that is never wider than
the bar, degrading itself internally. The same reasoning is recorded in the code
comment above the item.

**How to access:** the geometry is measurable headlessly —
`Tests/CasperUITests/WorkspaceTitleLabelTests.swift` hosts the label at a sweep
of hostile widths (220 down to 40pt) and asserts its height never leaves the
one-line baseline. Removing `.lineLimit(1)` moves those heights to
32/64/112/304, so the assertion has teeth (see
[[headless-swiftui-layout-tests]]).

Graceful degradation under the line limit: wrap the candidates in
`ViewThatFits(in: .horizontal)` ordered widest-first, so *context* (the Space
name) is dropped whole rather than truncated to an ellipsis stub while
*identity* (the branch) survives and middle-truncates only as a last resort.
