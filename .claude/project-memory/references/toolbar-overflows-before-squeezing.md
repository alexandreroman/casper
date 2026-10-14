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

Four AppKit behaviours the title bar is built around:

- **One item, one measured width.** With a single item there is nothing for
  AppKit to single out, so `WorkspaceDetailView` puts the entire row in one
  `ToolbarItem` under `.frame(width: rowWidth)` and degrades it internally.
- **AppKit runs its fit check during the resize and never re-runs it.** At a
  width where the row really is too wide, nothing brings it back —
  `validateVisibleItems()`, cycling `displayMode` or `toolbar.isVisible` and
  nudging the window all do nothing. So the row's width has to be right at the
  moment AppKit looks, which makes every input to it load-bearing.
- **That check judges the width the row declared for the PREVIOUS layout pass.**
  `rowWidth` comes from `detailFrame`, captured through `.onGeometryChange` into
  `@State`, so it is one pass behind the window by construction: SwiftUI cannot
  measure and re-declare inside the pass AppKit lays out. A window dragged
  narrower faster than the row's slack per pass therefore overflows the item for
  a frame; dragged wider, the stale width is narrower than the bar, which only
  wastes points nobody sees.
- **The one lever that does re-trigger the check** is invalidating the item
  *views'* intrinsic size, which is what `WorkspaceDetailView`'s
  `healToolbarOverflow()` does — measured on the running app at a 400 pt shrink
  jump, it brings a wrongly-clipped row back immediately. It heals a row that
  now fits but was measured stale; it cannot rescue a row that genuinely does
  not fit.

How the row is built on top of these — the safety margin, the capped and
ratcheted resize undershoot, the single ordered ladder, the sidebar-collapse
case and the measured chevron rates — is the design in app-ui.md § Title bar.

**How to access:** the row is `WorkspaceTitleBarRow` in
`Sources/CasperUI/WorkspaceTitleBar.swift`; its width constants and the heal
live in `Sources/CasperUI/WorkspaceDetailView.swift`. The chevron is observable
without a screen-recording grant: an `NSToolbarClippedItemsIndicator` in the
window's view tree is the reliable signal. Item counts are **not** — SwiftUI's
own `com.apple.SwiftUI.splitViewSeparator-0` is missing from `visibleItems` at
every width, chevron or no chevron. Three `#if DEBUG` environment variables
measure the row from inside the running app — `CASPER_TIERPROBE_WIDTHS`,
`CASPER_RESIZESTEP` and `CASPER_RESIZETRACE`; their usage and field meanings are
in the header of `WorkspaceDetailView+ToolbarProbe.swift`.

Related: [[toolbar-item-ignores-max-width]], [[toolbar-group-truncation]],
[[headless-swiftui-layout-tests]].
