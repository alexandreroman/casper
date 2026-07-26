---
name: "Headless SwiftUI layout smoke tests"
description: "SwiftUI views can be geometry-verified headlessly in XCTest via NSHostingView + fittingSize, even though pixels cannot be screenshot-verified"
type: feedback
---

# Headless SwiftUI layout smoke tests

A SwiftUI view's **layout geometry** is testable headlessly in XCTest: host it in
`NSHostingView(rootView:)`, call `layoutSubtreeIfNeeded()`, and read
`fittingSize`. No window, no run loop, no sleeps, no running app — the whole
measurement is synchronous and takes ~2ms. Put such tests in a `@MainActor`
`XCTestCase`, matching the rest of the UI suite.

**Why:** this does not contradict
[[agent-visual-verification-limits]] — that note is about *pixels* (screenshots
need a screen-recording TCC grant agents lack). Geometry is a different thing and
needs no permission at all, so the "agents can't verify SwiftUI" limitation is
narrower than it looks: colors, spacing polish, and chrome still need human eyes,
but "does it build, compose, and lay out to sane dimensions" is automatable.

**How to apply:** worthwhile assertions are the ones a broken body would flunk —
a fixed width holding against a pathologically long interpolated string, a
`lineLimit(_:reservesSpace:)` height staying bounded, a view not collapsing to
zero. Before trusting such a test, **prove it has teeth**: measure the same body
with the constraint removed and confirm the number moves. For
`WorkspaceCloseProgressView` the constrained sheet measures 340×136 while the
same content without `.frame(width:)` measures 2426pt wide, so the width
assertion is real rather than an artifact of `fittingSize`.

Two caveats found in practice:

- `TimelineView` **does** evaluate its content headlessly (its branch measures
  identically to the equivalent plain `Text`), so countdown/timer paths are
  reachable in tests.
- Reserved-space line limits *hide* content emptiness: a label area pinned to two
  lines yields the same height whether the text renders or not. Such a test pins
  down "composes and lays out", not "the text is non-empty" — say so in the test's
  doc comment instead of overclaiming.

When a view's fixed dimension is a bare literal, exposing it as a `static let` on
the view and asserting against that is preferred over duplicating the number in
the test.
