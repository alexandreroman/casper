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
- **`rowWidth` undershoots on purpose, in two terms.** A row narrower than the
  bar leaves a few invisible points at the right, while a row wider than the bar
  empties the whole title bar into the chevron, so the width is sized to lose
  that race. The standing term (`safetyMargin`, 24 pt) covers a **still** window
  and no more: AppKit's item viewer starts 8 pt inside the detail area, leaving
  ~16 pt of real slack. The second term covers a window in motion — see the
  bullet on the fit check below.
- **AppKit runs its fit check during the resize and never re-runs it.** At a
  width where the row really is too wide, nothing brings it back —
  `validateVisibleItems()`, cycling `displayMode` or `toolbar.isVisible` and
  nudging the window all do nothing. So the row's width has to be right at the
  moment AppKit looks, which makes every input to it load-bearing.
- **That check judges the width the row declared for the PREVIOUS layout pass.**
  `rowWidth` comes from `detailFrame`, captured through `.onGeometryChange` into
  `@State`, so it is one pass behind the window by construction: SwiftUI cannot
  measure and re-declare inside the pass AppKit lays out. A drag that
  narrows the window by more than the ~16 pt of standing slack per pass
  therefore overflows the item for one frame, `healToolbarOverflow()` brings it
  back on the next, and that cycle once per frame of the drag is a visible
  flicker. Dragging WIDER is safe for the same reason reversed: the stale width
  is narrower than the bar, which only wastes points nobody sees. Measured on
  the running app, `chevron=YES` at the instant AppKit lays out: 18/19 shrink
  steps at 40 pt per pass, 6/8 at 16 pt, 1/14 at 8 pt, and 0/19 growing at every
  step size.
- **What covers it is anticipation, not recovery**: `rowWidth` subtracts the
  shrink the previous pass measured, so the stale value already fits the bar of
  the pass that follows. Within the cap described below it is complete — a
  hand-driven drag traced over 485 samples shows no chevron on any pass whose
  delta the cap covers, and no rung climbing back while the window narrows (the
  climb-backs a trace does show all occur while widening, which is the correct
  answer to a widening window). Past the cap it deliberately falls short: the
  same trace shows 8 chevron frames, every one of them on a coalesced pass of
  97-558 pt. That residual is an accepted trade, chosen over a row that folds
  for the whole drag. The clamp at `minimumRowWidth` is load-bearing: an item
  undershot out of the toolbar unmounts and remounts once per frame, which is
  worse than the overflow.
- **Three properties make that undershoot safe on a hand-driven drag**, and a
  trace of one shows why each is needed. The measured delta is not a per-frame
  increment: SwiftUI coalesces layout passes, so it is the whole distance
  travelled since the last pass and is unbounded: a 990 -> 428 pt drag
  arrived as ONE pass of 562 pt. So the undershoot is **capped**
  (`maximumResizeUndershoot`, 40 pt: twice the fastest ordinary pass, measured
  at 5-20 pt, and just under one `...` chip plus its gap); beyond that bound the
  right outcome for an unanticipatable jump is the one frame of chevron
  `healToolbarOverflow` recovers, not a row collapsed onto the ladder's floor.
  It is **ratcheted** while `NSWindow.inLiveResize` — within one drag it may
  only grow — because the declared width must be monotone while the window is
  dragged narrower: the ladder is chosen from that width, so a width that falls
  and rises again brings the badge, the Space name and the chip labels back
  mid-drag, which is the non-monotone degradation the single ordered ladder
  exists to prevent. And it is **released only after the drag ends**: a human
  drag is bursts of passes separated by pauses that outlast the settle delay, so
  the debounce re-arms while the resize is still live rather than handing the
  width back into a pause for the next burst to take away again. Outside a live
  resize (a zoom, a programmatic `setFrame`) the capped delta applies as-is,
  anticipated once. The decision is the pure
  `WorkspaceDetailView.nextUndershoot(current:shrink:isLiveResize:)`, pinned by
  `WorkspaceTitleBarWidthTests`; the view keeps only the `@State`, the
  live-resize read and the re-arming debounce.
- **Two adjacent cases the anticipation cannot reach**, both left to
  `healToolbarOverflow()`: a jump with no previous pass to learn from (a zoom, a
  display change, content growing while the window stands still), and
  **collapsing the sidebar** — `windowChromeReserve` flips on
  `detailFrame.minX < 1` while the detail area *grows*, so the shrink term is
  zero and the previous pass's declared width, taken before the 140 pt reserve
  applied, exceeds the bar the collapsed window offers. Expanding is the safe
  mirror image. Deriving the shrink term from the chrome-adjusted widths instead
  would subsume that case and hold ~140 pt of undershoot for the whole settle
  delay, folding the chip row visibly on every collapse.
- **`willStartLiveResizeNotification` does not close the residual first pass.**
  It cannot know the drag's direction, so it can only pre-arm a fixed budget —
  which would fold the chips at the start of every GROW drag, where no artifact
  exists at any measured step size, in exchange for one frame at the start of a
  shrink that the heal already catches.
- **The one lever that does re-trigger the check** is invalidating the item
  *views'* intrinsic size, which is what `WorkspaceDetailView`'s
  `healToolbarOverflow()` does — measured on the running app at a 400 pt shrink
  jump, it brings a wrongly-clipped row back immediately. It heals a row that
  now fits but was measured stale; it cannot rescue a row that genuinely does
  not fit.

**How to access:** the row and its constants live in
`Sources/CasperUI/WorkspaceDetailView.swift`. The chevron is observable without
a screen-recording grant: an `NSToolbarClippedItemsIndicator` in the window's
view tree is the reliable signal. Item counts are **not** — SwiftUI's own
`com.apple.SwiftUI.splitViewSeparator-0` is missing from `visibleItems` at every
width, chevron or no chevron. Three `#if DEBUG` environment variables live in
`WorkspaceDetailView+ToolbarProbe.swift`, and two of them drive the three
sweeps: `CASPER_TIERPROBE_WIDTHS` walks a list of widths and then drives every
sidebar x inspector combination to the window's floor, while
`CASPER_RESIZESTEP="from,to,step,delayMs"` replays a
stepped shrink and the same walk back up, sampling **twice per stop** — once
synchronously after the `setFrame`, before SwiftUI's next pass, and once after
the delay. That first sample is the only way to see a one-frame overflow at all;
the settled sweeps structurally cannot. Across the pair `chevron=` is the
authoritative field, and `overhang=` understates the real overrun by the item
viewer's inset, so it reads negative on a stop whose `chevron=` says `YES`.

The third variable, `CASPER_RESIZETRACE=1`, drives nothing at all: it arms a
passive `TIERPROBE TRACE` and waits for the window to be dragged **by hand**,
logging one line per layout pass that moves the detail area (plus one whenever
the declared width or the ladder rung changes for another reason) with `delta=`,
`undershoot=`, `row=`, `live=` (`NSWindow.inLiveResize` — the window's flag,
not the content view's, since which views AppKit resizes inside its tracking
loop is an implementation detail), `chevron=`, and `rung=`, the ladder rung
`ViewThatFits` placed, numbered widest-first and reported by that rung's own
`background` (only the selected candidate is ever laid out, so the report names
the rung on screen). A pointer drag is the only source of two facts a stepped
sweep cannot produce — a real live resize, and a per-pass delta that
**fluctuates**, which makes the declared width fluctuate non-monotonically
because it subtracts that delta, and can walk the ladder back UP a rung
mid-drag. Read a trace in runs of consecutive `live=YES` samples: a `rung=` that
goes down and back up inside one run is the ladder oscillating (a flicker of the
chips, fixed in how the width is derived), a `chevron=YES` sample is the
overflow (a flicker of the whole bar), and the two are independent failures with
different fixes.

Related: [[toolbar-item-ignores-max-width]], [[toolbar-group-truncation]],
[[headless-swiftui-layout-tests]].
