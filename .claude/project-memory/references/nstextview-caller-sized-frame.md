---
name: "A caller-sized NSTextView must not be vertically resizable"
description: "When the caller assigns the frame from a measured height, isVerticallyResizable lets AppKit override it with the lazily laid-out extent"
type: reference
---

# A caller-sized NSTextView must not be vertically resizable

`MarkdownTextView` is sized by its caller: `WorkspaceInfoPanel` hands the view a
height through `.frame(width:height:)`. Where that height comes from is a
separate question, settled in [[textkit1-fallback-on-nstexttable]] — the view
reports what it has really laid out and the panel takes the larger of that and
`MarkdownTextView.height(for:width:)`, because the two disagree whenever the
live view has fallen back to TextKit 1.

An `NSTextView` with `isVerticallyResizable = true` computes its own frame
height from the text it has laid out, and that self-sizing **wins over the frame
SwiftUI assigns**. TextKit 2 lays out viewport-first, so the height it lands on
falls short of the document whenever the message is long enough to scroll, and
the tail is never drawn — measured in the info panel at 1263 pt of laid-out text
(`usageBoundsForTextContainer`, agreeing with `height(for:width:)`) inside a
1000 pt view frame, while the SwiftUI `ScrollView`'s document view holds the
correct 1263 pt. The same probe at other lengths lands short by the same shape
(835 → 726, 2547 → 1822, 4259 → 2918), never over. With
`isVerticallyResizable = false` the view keeps the assigned frame exactly.

The **container's** bounds are a separate axis from the view's resizability: the
container is built with `CGSize(width: width, height: 0)`, which TextKit 2 reads
as unlimited, and `heightTracksTextView` stays false — so layout is unclipped
either way, confirmed by `usageBoundsForTextContainer` still reporting the full
extent with the view non-resizable. Only `widthTracksTextView` matters for
wrapping.

Pinned by `WorkspaceInfoPanelTests.testTallMessageKeepsTheFullMeasuredHeightInTheTextView`,
which compares the hosted text view's `frame.height` against
`height(for:width:)` for a **table-free** message — the case where the
measurement and the live view's own layout are the same number. Such a test
needs a real `NSWindow` around the
`NSHostingView`: without one, a SwiftUI `ScrollView`'s document view never lays
out and the frame says nothing (see [[headless-swiftui-layout-tests]]).

Not in tension with the layout-cost bullet in [[textkit2-layout-geometry]] —
that one measures the `NSScrollView`-hosted diff surface, where the resizable
text view forces full layout at its layout pass. What the info panel measures is
the frame the view ends up with, which is the number a caller-sized view must
not own.
