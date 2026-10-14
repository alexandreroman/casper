---
name: "Diff surface data flow"
description: "The diff document reaches DiffTextSurface as a representable property keyed by a monotonic revision; only events go through DiffSurfaceController"
type: project
---

# Diff surface data flow

`DiffSurfaceView` hands the diff to `DiffTextSurface` as a `DiffRendering`
**property** (revision + `DiffDocument` + carried highlights), and
`updateNSView` applies it via `Coordinator.render(_:)`.

**Why:** SwiftUI creates the coordinator only when it realizes the
representable, and the body that first shows the surface runs *after* the
refresh that produced the document — so at the moment a refresh finishes there
is no coordinator to push to. Pushing from `.onAppear` instead makes the first
paint depend on SwiftUI running `makeCoordinator()` before `.onAppear`, an
ordering Apple does not document. As a property it cannot be missed: SwiftUI
calls `updateNSView` on realization and on every update after it. The flow is
strictly one-way (SwiftUI → AppKit), so it writes no state during layout — the
feedback path the whole TextKit rewrite exists to remove.

**How to apply:**

- **Compare the revision, never the document.** `updateNSView` runs on every
  SwiftUI update and `DiffDocument` holds the entire diff text, so
  `Coordinator.appliedRevision` is the guard. Re-applying an already-rendered
  document would also drop the reader's text selection.
- **Anything the swap invalidates belongs inside `render`.** The scroll anchor
  is read from the live surface immediately before the swap, and the carried
  highlights are repainted immediately after it — `DiffTextAssembly` builds the
  fresh storage from base attributes only. The repaint precedes the anchor
  restore: painting invalidates layout, and the restore can force a
  whole-document layout pass (see the last bullet), which a later paint would
  throw away — along with the anchor it placed
  (`testCarriedHighlightsAreOnTheTextWhenARefreshLaysItOut`).
- **Events stay on `DiffSurfaceController`.** A scroll target and a file's
  syntax colors finishing are events, not state; they tolerate a nil coordinator
  and are retried. `Coordinator.scroll(toFileID:)` returns whether the surface
  took the scroll: it lands at once, or — on a surface not sized yet — on the
  layout that sizes it (see the next bullet). `DiffSurfaceView` clears
  `AppModel.diffScrollTarget` through `consumeDiffScrollTarget(_:)` once the
  surface takes it, or once a diff computed at the target's `diffRevision` or
  later lacks the file. A target naming a file that only the freshly computed
  diff holds therefore survives until the document reaches the surface, and a
  settled one cannot fire again when the view remounts (collapse, Browser tab,
  workspace switch).
- **SwiftUI sizes the hosted view *after* `updateNSView`.** A document can
  therefore arrive while the container is still zero-sized, which silently
  resolves anything viewport-derived against an empty viewport — for the pinned
  file header that means no bars until the reader's first scroll.
  `DiffSurfaceContainerView.viewportDidChange` fires from `layout()` and re-runs
  `Coordinator.resolveBarsOverTheViewport()` for exactly this reason. Any future
  viewport-derived state needs the same hook. A scroll target is one: a
  `casper diff open` that expands a collapsed panel or leaves the Browser tab
  mounts a surface, and its target reaches the realized coordinator before the
  first sizing pass, when the clip view clamps any scroll to the top. The
  coordinator holds the file and the same hook lands it. The text view grows
  to the document's height only in its own layout pass, which runs after the
  container's and, on a sized surface, after a document swap, so the clip view
  would clamp either scroll short. `scroll(toViewY:)` is the one place that
  handles it: it lays the text view out first whenever the target lies past
  the text view's current height.

`Tests/CasperUITests/DiffTextSurfaceTests.swift` pins the scenario: a document
that exists *before* the surface is realized must render on
`layoutSubtreeIfNeeded()` alone, with no imperative call.
`Tests/CasperUITests/DiffSurfaceViewScrollTests.swift` pins the scroll target
end to end, through the real `InspectorPanel` expanding from collapsed and
switching from the Browser tab.
