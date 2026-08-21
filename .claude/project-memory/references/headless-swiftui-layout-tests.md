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

**Host the view inside the container it ships in.** A body that is a `TupleView`
of several elements — a `Divider` plus a `VStack`, say — is flattened by whatever
stack the production parent provides. Hosted bare, `NSHostingView` supplies
container semantics of its own, so the measured number is not the one the real
parent gets and a broken flattening cannot fail the test. Wrap the subject in the
same `VStack(spacing: 0) { … }` (or equivalent) the shipping call site uses.

**A hosted view measures differently on the CI runner than on the development
machine**, so a fixture must never depend on an absolute position or on which
content a given offset lands on. Two divergences are measured, both from the same
`NSHostingView` sized 480×600:

- the runner shows **legacy scrollbars**, so an `NSScrollView`'s clip view is
  465 pt wide there against 480 pt locally (overlay scrollers), and its text view
  407 pt against 422 pt — enough to change where wrapped text breaks;
- the runner is **macOS 15** while development is on macOS 26, and TextKit's cold
  layout estimates differ between them — see [[textkit2-layout-geometry]].

**How to apply:** build such a fixture so the property under test holds under any
monotone mapping from offset to content. For "a file boundary must be visible in
the viewport", that means many files each shorter than the viewport — a boundary
is then in view wherever the viewport lands — rather than a few tall files with a
single boundary placed by arithmetic that only holds on one OS. And when a bound
is compared against a bound (a band the overlay emits against a band the text
draws), make the two bounds agree explicitly instead of relying on the fixture
never landing on the edge case.
