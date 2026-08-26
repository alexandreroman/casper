---
name: "AppKit overflows a SwiftUI toolbar item rather than shrinking it"
description: "An NSToolbar sizes a SwiftUI ToolbarItem to its content's ideal width and never squeezes it; too little room sends the whole item into the chevron popover, and after that only invalidateIntrinsicContentSize() re-checks"
type: reference
---

# AppKit overflows a SwiftUI toolbar item rather than shrinking it

AppKit sizes a SwiftUI `ToolbarItem` to its content's **ideal** width and never
proposes it less. When the bar is too narrow, the item goes into the `»`
overflow popover **whole** — where custom SwiftUI chips render chrome-less and
clipped, so the visible symptom points at the chip rather than at the layout.

This holds for every item, the truncatable ones included: measured at a 600 pt
window, the leading group — a plain `HStack` of `Text` under `.lineLimit(1)` —
reported 293 pt and went into the chevron with its title still on one line
rather than shortening. No width arithmetic *inside* an item can prevent that;
only the item's own reported width decides its fate.

Three consequences the title bar is built around:

- **One item, one measured width.** `WorkspaceDetailView` puts the entire row —
  title capsule, info chip, diff badge, Merge, Run, Editor, selector — in a
  single `ToolbarItem` under `.frame(width: rowWidth)`. With one item there is
  nothing for AppKit to single out, and the row degrades internally instead: the
  title carries `.layoutPriority(2)` and never drops, while one widest-first
  ladder chooses the badge and the chip tier **together**
  (`badge + full → full → compact → folded → minimal`). One ladder per element
  cannot rank two elements against each other — with the badge on its own layout
  priority it vanished at 500 pt and came back at 260 pt, because folding the
  chips freed room that SwiftUI handed straight back to it, and degradation ran
  backwards.
- **`rowWidth` undershoots on purpose** (`safetyMargin`): a row narrower than the
  bar leaves a few invisible points at the right, while a row wider than the bar
  empties the whole title bar into the chevron.
- **An overflowed item recovers only when it genuinely fits again.** AppKit runs
  its fit check during the resize and never re-runs it; at a width where the row
  really is too wide, nothing brings it back — not `validateVisibleItems()`, not
  cycling `displayMode` or `toolbar.isVisible`, not
  `invalidateIntrinsicContentSize()`, not nudging the window. So the row's width
  has to be right at the moment AppKit looks, which makes every input to it
  load-bearing.

**How to access:** the row and its constants live in
`Sources/CasperUI/WorkspaceDetailView.swift`. The chevron is observable without
a screen-recording grant: an `NSToolbarClippedItemsIndicator` in the window's
view tree is the reliable signal. Item counts are **not** — SwiftUI's own
`com.apple.SwiftUI.splitViewSeparator-0` is missing from `visibleItems` at every
width, chevron or no chevron. A `#if DEBUG` sweep driven by
`CASPER_TIERPROBE_WIDTHS` resizes the window through a list of widths and logs
that state at each one.

Related: [[toolbar-item-ignores-max-width]], [[toolbar-group-truncation]],
[[headless-swiftui-layout-tests]].
