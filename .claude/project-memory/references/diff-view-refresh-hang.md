---
name: "Diff-view main-thread hang on refresh (open incident)"
description: "Unreproduced SwiftUI-layout hang in the diff view triggered on refresh; lazy rendering + a diagnostic log line are in place to capture the next occurrence"
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
Mitigation already in place: `DiffFileView`'s inner container is a `LazyVStack`
(only on-screen rows lay out). Batching the per-file highlight publication was
tried and deliberately reverted to keep progressive coloring — once rows render
lazily, per-file `@State` updates only re-lay-out visible rows, so batching was
unproven and not worth the UX cost. Do not re-add batching without a real repro.
