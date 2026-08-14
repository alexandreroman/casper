---
name: "Sticky bars have three invalidation paths, and a test must isolate one"
description: "The anchor restore moves the clip view during the layout pass, so the scroll path re-resolves the diff's sticky bars and can hide a missing settled-layout trigger"
type: reference
---

# Sticky bars have three invalidation paths, and a test must isolate one

`DiffStickyHeader.bars` is a cache with three invalidation triggers (document swap
or resize, clip-view bounds change, and TextKit's layout settling through
`DiffTextView.didLayout`). Any one of them can produce correct bars on its own,
which makes a test for *one* of them worthless unless the fixture keeps the other
two out of the way.

The path that hides the settled-layout trigger is the scroll one, reached without
any scrolling: `Coordinator.restore(_:)` scrolls the clip view to the anchor
file's top in the **new** document, and that scroll lands during the following
layout pass — so the bounds-change notification arrives *after* TextKit has
settled and re-resolves the bars over real geometry. Measured on a 300-file
fixture whose refresh grows every file by one line, the anchor file's top moves
12 665 pt, and the test passes with `didLayout` deleted.

**Keep the refreshed document the same height above the reader** and the restore
lands on the same container `y`, no bounds change fires, and the estimate residue
is the only thing left moving the text — which is the thing under test. A refresh
that appends a file at the end of the diff does that; one that grows every file
does not.

**A test waiting on the coalesced re-resolution drains the main run loop to idle,
not for one pass.** `NSHostingView.rootView` is not guaranteed to reach
`updateNSView` synchronously, so a single `CFRunLoopRunInMode(.defaultMode, 0,
false)` can be spent applying the document swap and running the layout pass it
provokes — the pass that queues the re-resolution, for the *next* turn, through
`CFRunLoopPerformBlock`. Whether that costs one turn or two depends on what ran
before, which shows up as a test that passes alone and fails in the full suite.
Draining while the loop answers `.handledSource`, with a hard iteration cap,
matches the app's steady state and leaves a coalescing count assertion intact:
passes with nothing pending resolve nothing.

Depth is not monotone in this. The residue is the difference between the estimated
and the real pitch of the files above the viewport (312 pt real against 266 pt
estimated for 3 wrapping lines plus a hunk header, ~6 900 pt at 150 files deep),
but `restore` forces real layout as far as the anchor file, so an anchor near the
end of the document leaves almost nothing estimated: at 250 files of 300 the
residue is 0 and the fixture has no teeth. Around half-way in it is thousands of
points. Any fixture in this area has to be proven by deleting the trigger and
watching it fail.
