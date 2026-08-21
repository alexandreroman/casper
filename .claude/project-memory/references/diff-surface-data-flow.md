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
  fresh storage from base attributes only.
- **Events stay on `DiffSurfaceController`.** A scroll target and a file's
  syntax colors finishing are events, not state; they tolerate a nil coordinator
  and are retried. `Coordinator.scroll(toFileID:)` returns whether it landed,
  and `DiffSurfaceView` consumes the target's nonce only then, so a target
  naming a file that only the freshly computed diff holds survives until the
  document reaches the surface.
- **SwiftUI sizes the hosted view *after* `updateNSView`.** A document can
  therefore arrive while the container is still zero-sized, which silently
  resolves anything viewport-derived against an empty viewport — for the pinned
  file header that means no bars until the reader's first scroll.
  `DiffSurfaceContainerView.viewportDidChange` fires from `layout()` and re-runs
  `Coordinator.resolveBarsOverTheViewport()` for exactly this reason. Any future
  viewport-derived state needs the same hook.

`Tests/CasperUITests/DiffTextSurfaceTests.swift` pins the scenario: a document
that exists *before* the surface is realized must render on
`layoutSubtreeIfNeeded()` alone, with no imperative call.
