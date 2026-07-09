---
name: "Diff-view main-thread hang on refresh (open incident)"
description: "Unreproduced SwiftUI-layout hang in the diff view triggered on refresh; a diagnostic log line is in place to capture the next occurrence (the lazy-rendering mitigation was reverted — it broke layout)"
type: project
---

# Diff-view main-thread hang on refresh (open incident)

The diff view can hang the main thread for minutes while laying out (a real
spindump showed ~377 s stuck in SwiftUI layout: `StackLayout` /
`_FlexFrameLayout` / `StyledText.sizeThatFits`). It presents as a beachball, not
a crash, so it leaves NO `.ips` crash report — only a spindump/"Stackshots"
report. It was triggered on a diff-view **refresh** (not just on open). This is
distinct from the older HighlightSwift `Bundle.module` SIGTRAP — see
[[highlightswift-resource-bundle]].

**Why it is not fully fixed:** the hang could not be reproduced with synthetic
diffs — open AND refresh paths, short lines, long wrapping lines, up to 40 files
× 800 lines all stayed responsive (~35 ms) on the pre-fix code. So the trigger
is something specific to the real diff content that plain scale does not
capture; the leading suspect is a file with a very long single line (minified
bundle / one-line data / lockfile), since `StyledText.sizeThatFits` on wrapping
text dominates the stuck stack.

**How to apply / diagnose next time:** `DiffSurfaceView.refresh()` logs one
`.notice` line per refresh via `CasperLog.app`:
`diff refresh: files=… lines=… maxFileLines=… maxLineLen=… computeMs=…`. When the
hang recurs, read that LAST line before the freeze — `maxLineLen` (longest
`GitDiffLine.content`) is the key signal for a huge-single-line culprit. Capture
it with `/usr/bin/log show --predicate 'subsystem ==
"com.github.alexandreroman.casper"' --info` (or the `debug-casper` stream).

**The `LazyVStack` mitigation was reverted.** `DiffFileView`'s inner container
was briefly a nested `LazyVStack` (commit 339334e) to virtualize rows, but a
lazy stack nested as a `Section`'s content inside the outer `LazyVStack`/
`ScrollView` cannot report an exact height: it over-reserves vertical space and
leaves large empty gaps between files. It is back to a plain `VStack`. Row count
is still bounded by `DiffFileView.maxRenderedLines` (3000), and the outer
`LazyVStack` still virtualizes at the per-file level. The correct guard for the
huge-single-line hang, when reproduced, is a per-line content-length cap in the
render path (bounding `StyledText.sizeThatFits`) — NOT a nested lazy stack.

Batching the per-file highlight publication was tried and deliberately reverted
to keep progressive coloring; do not re-add it without a real repro.
