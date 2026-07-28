---
name: "Diff-view main-thread layout hang"
description: "The diff view can spin the main thread at ~98% CPU in a non-converging SwiftUI layout recursion; root cause is an explicit alignment guide on the pinned file header, plus the diagnostic recipe and the falsified hypotheses"
type: project
---

# Diff-view main-thread layout hang

The diff view is susceptible to a non-converging SwiftUI layout recursion that
spins the main thread at ~98% CPU. It presents as a frozen window, not a crash,
so it leaves **no `.ips` crash report** — only a live `sample`, a system
`.hang`/spindump (`/Library/Logs/DiagnosticReports/casper_*.hang`), or the
in-app watchdog dump (`~/Library/Logs/Casper/hang-<timestamp>.txt`).

**Why:** three separate causes in this family have been diagnosed, and each was
initially mistaken for the previous one. The signature markers below are what
tell them apart; without them, a session re-chases dead ends that are already
falsified.

**How to apply:** identify which variant is active from the frame counts before
proposing anything.

## Diagnostic recipe

1. `ps -o %cpu,state -p <pid>` — state `R` at ~98% means a spin, not a deadlock.
2. `sample <pid> 3 -file /tmp/casper-sample.txt`, twice, a few minutes apart. A
   stable-or-growing count across both samples means it is not converging.
3. Count the discriminating frames:
   - `explicitAlignment` dominant (hundreds) → alignment-guide recursion.
   - `StyledTextLayoutEngine` / `NSAttributedString.MetricsCache` dominant →
     text-metrics recursion, bounded by the `DiffLineStyle` caps.
   - `NSAnimationContext` / `runAnimationGroup` / `motionVectors` present in
     quantity → animated-relayout churn.
   Fewer than ~10 frames of a marker is background noise, not the driver.
4. `refresh()` logs one `.notice` per refresh (`diff refresh: files=… lines=…
   maxFileLines=… maxLineLen=… computeMs=…`) via `CasperLog.app`. Read it with
   `log show --predicate 'subsystem == "com.github.alexandreroman.casper"'
   --info --debug`. A flood of these with unchanged `files=`/`lines=` is the
   churn signature. Release builds often persist nothing, so treat an empty
   result as no evidence rather than as absence of churn.

Watchdog dumps whose main thread sits in `mach_msg_trap` capture a different
phenomenon and are not this hang.

## Root cause: explicit alignment guides in a pinned header

An explicit alignment guide (`.lastTextBaseline`, `.firstTextBaseline`) in a
stack that also holds a flexible-width child forms a circular layout
dependency: resolving the guide requires the child's baseline, the child has no
intrinsic width so its baseline depends on the width it is proposed, and that
width depends on the stack's sizing, which is waiting on the guide. As a
**pinned** section header (`pinnedViews: [.sectionHeaders]`) the row is
re-placed by `LazySubviewPlacements` on every layout pass, so the cycle is
entered continuously and never settles.

The dump chain for this variant is `LazySubviewPlacements.placeSubviews` →
`LazyStack.place` → `_PaddingLayout` → `StackLayout` → `_FlexFrameLayout` →
`_HStackLayout.explicitAlignment` → `StackLayout.placeChildren` (cycle).

`DiffFileHeaderBar` therefore uses implicit (center) alignment, and the
codebase contains no explicit baseline guide. Center alignment derives from the
child's height and never re-enters placement. The constraint is recorded as a
comment on the view itself.

## Falsified hypotheses — do not re-chase

- **Long single lines / large diffs.** A release build (726) shipping the
  `DiffLineStyle.truncatedForDisplay` 2000-char cap hung on a benign diff
  (`maxLineLen=278`, 14 Markdown/YAML files). The caps are worth keeping; they
  are not what resolves this.
- **Animated relayout churn as the sole cause.** Dedup of redundant refreshes
  plus `Transaction.disablesAnimations` removed the animation frames from the
  dumps (8–11 before, ~0 after) and the main thread still spun. Both mitigations
  remain correct and stay in place; they address one variant only.
- **Row-layer bounds as the remedy for the alignment variant.**
  `DiffLineStyle.maxWrappedLinesPerRow` and
  `.fixedSize(horizontal: false, vertical: true)` on the code text bound the
  text-metrics variant. `DiffLineRow` aligns with `.top`, which issues no
  baseline query, so these caps cannot affect an `explicitAlignment` recursion.
  They stay as defense-in-depth for the variant they do cover.

## Verification limits

None of these variants reproduces headlessly: an unbundled debug binary's
window counts as not-visible, so `applyWatcherVisibility` stops the FSEvents
watchers and no refresh fires. Confirming a fix needs a visible real instance
left running with the diff view open on an actively-edited worktree. See
[[agent-visual-verification-limits]]. As of 2026-07-28 the header fix has this
live confirmation outstanding.

## Layout constraints that must hold

- `DiffFileView`'s inner container is a plain `VStack`. A lazy stack nested as
  a `Section`'s content inside the outer `LazyVStack`/`ScrollView` cannot report
  an exact height, which leaves large empty gaps between files.
- Per-file highlight publication stays per-file, each in its own
  animation-disabling transaction. Batching it breaks progressive coloring.
- `pinnedViews: [.sectionHeaders]` stays; the sticky-header feature is
  intended.
