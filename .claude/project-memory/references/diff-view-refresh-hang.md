---
name: "Diff-view main-thread hang on refresh (animated cause fixed; non-animated variant still open)"
description: "SwiftUI-layout hang in the diff view: the animated LazyVStack-relayout trigger was fixed (dedup + disablesAnimations), but a second, NON-animated variant still hangs build 766 via unbounded StackLayout/_FlexFrameLayout/StyledText recursion; being bounded via defense-in-depth"
type: project
---

# Diff-view main-thread hang on refresh (animated cause fixed; non-animated variant still open)

**2026-07-21 update — the 07-16 fix is INCOMPLETE.** A release build 766
(post-fix, binary from 2026-07-20) hung again with a diff view open. A live
`sample` + the watchdog auto-dump (`~/Library/Logs/Casper/hang-20260721-165800.txt`,
PID 24431, ran 5h then hung at 16:58) show the animation fix HOLDS
(`NSAnimationContext`/`runAnimationGroup` = 0, vs 8–11 in pre-fix dumps) but the
main thread still busy-loops (99% CPU, state R) in a **non-animated** unbounded
layout recursion: `ViewLayoutEngine.explicitAlignment` ⇄
`LayoutEngineBox.sizeThatFits` ⇄ `StackLayout.sizeChildrenGenerally…` ⇄
`_FlexFrameLayout.sizeThatFits` ⇄ `StyledTextLayoutEngine`/
`NSAttributedString.MetricsCache`, deep enough to hit `___chkstk_darwin` (×47).
So the earlier claim "animation churn is the SOLE cause" is falsified — the
underlying `StackLayout ⇄ _FlexFrameLayout.sizeThatFits` recursion can diverge
on a purely content/geometry-driven, non-animated path too. Diagnostic gaps this
time: os_log did not persist for the release build (`log show` returned 0 lines
for the subsystem), and the watchdog dump does not embed the `diff refresh:`
shape line, so the exact triggering file/geometry is unknown.

**Fix in progress (defense-in-depth, 2026-07-21).** Rather than chase the exact
trigger (unreproducible headlessly — see [[agent-visual-verification-limits]]),
bound the runaway at the row layer: cap wrapped visual lines per code row
(`.lineLimit`, the vertical analog of `maxDisplayLineLength`) and remove the
flexible-frame free variable on the wrapping code text
(`.fixedSize(horizontal: false, vertical: true)`), on top of the existing
`maxDisplayLineLength = 2000` and `maxRenderedLines = 3000` caps. NOT yet
verified on a live visible instance.

---

## Original entry (2026-07-16) — animated variant, fixed

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
