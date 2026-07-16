---
name: "Diff-view main-thread hang on refresh (diagnosed + fixed)"
description: "SwiftUI-layout hang in the diff view was caused by frequent-refresh animated LazyVStack relayout, not a long line; fixed by deduping identical-diff refreshes + disabling implicit animations on all diff-view state mutations"
type: project
---

# Diff-view main-thread hang on refresh (diagnosed + fixed)

The diff view could hang the main thread for minutes (a real macOS `.hang`
spindump showed ~378 s stuck) in a **non-converging SwiftUI layout transaction**:
`GraphHost.flushTransactions` → `LazyStack.place(…pinnedSubviews…)` → unbounded
`StackLayout` ⇄ `_FlexFrameLayout.sizeThatFits` recursion reaching
`___chkstk_darwin` (stack-growth probe). It presents as a beachball, not a crash,
so it leaves NO `.ips` crash report — only a spindump/`.hang`/"Stackshots" report
(look in `/Library/Logs/DiagnosticReports/casper_*.hang`).

**Root cause (identified 2026-07-16).** The trigger is diff-view **refresh
churn**, not diff content. On an actively-edited worktree an FSEvents watcher
bumps `model.diffRevision` very frequently; `DiffSurfaceView.refresh()` ran on
every bump, and many bumps recompute a byte-identical diff yet still reassigned
`diff`/`metrics` and re-drove `.scrollPosition`. Each mutation drove the
pinned-header `LazyVStack` into an **animated** subview relayout (the stuck
spindump path includes `Array.motionVectors`, `LazyLayoutViewCache.initialPlacement`,
`commitPlacedSubviews`, `+[NSAnimationContext runAnimationGroup:]`); back-to-back
animated relayouts never converge → permanent hang.

**Why:** this is why it was historically "unreproducible" — synthetic **static**
diffs (even 40 files × 800 lines, long wrapping lines) never churn, so they never
hit the animated-relayout storm. It reproduces on real, actively-changing
worktrees (e.g. a Temporal workshop repo mid-edit).

**The long-single-line hypothesis was FALSIFIED.** A release build (726) that
already shipped the `DiffLineStyle.truncatedForDisplay` 2000-char cap still hung
on the `auth-codec` workspace whose diff was benign (`maxLineLen=278`, Markdown/
YAML, 14 files). The `truncatedForDisplay` guard is still worth keeping, but it is
NOT what fixed this hang.

**The fix (in `DiffSurfaceView.swift`).**
1. **Dedup redundant refreshes:** in `refresh()`, if `loaded && newDiff == diff`
   (`GitDiff` is `Equatable`), skip all content work; only `applyPendingScroll()`
   still runs (a scroll target can arrive independent of a content change).
2. **Disable implicit animation** (`Transaction.disablesAnimations = true`,
   `withTransaction { … }`) on every diff-view state mutation that relayouts the
   `LazyVStack`: the `diff`/`metrics` assignment, the `scrolledFileID` scroll
   re-drive, the `highlights = carried` reset, and the per-file highlight
   publication.

**How to apply / diagnose next time.** `refresh()` still logs one `.notice` per
refresh (`diff refresh: files=… lines=… maxFileLines=… maxLineLen=… computeMs=…`)
via `CasperLog.app` — read it with `/usr/bin/log show --predicate 'subsystem ==
"com.github.alexandreroman.casper"' --info --debug`. A **flood** of these lines
(especially with unchanged `files=/lines=`) is the churn signature. For a live
hang, `sample <pid>` or the system `.hang` report shows whether the main thread
is in the `LazyStack.place` recursion. NOTE: the fix cannot be A/B-verified
headlessly — an unbundled debug binary's window is treated as not-visible, so
`applyWatcherVisibility` stops the FSEvents watchers and no refresh fires;
reproduction/verification needs a **visible real instance**. See
[[agent-visual-verification-limits]].

**Still-valid layout constraints (do NOT regress):**
- Do NOT nest a `LazyVStack` inside `DiffFileView`; its inner container stays a
  plain `VStack` (a nested lazy stack can't report exact height → huge gaps).
- Do NOT batch the per-file highlight publication — it breaks progressive
  coloring. Keep it per-file (the fix wrapped each publication in its own
  animation-disabling transaction, still per-file).
- Keep `pinnedViews: [.sectionHeaders]`; the fix removes animation + redundant
  churn, not the sticky-header feature.
