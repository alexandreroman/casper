---
name: "Diff-view main-thread layout hang"
description: "The diff view's non-converging SwiftUI layout cycle: its measured sample signature, why frame counts and diff size mislead, and the diagnostic recipe"
type: project
---

# Diff-view main-thread layout hang

The diff view is susceptible to a non-converging SwiftUI layout cycle that spins
the main thread at ~100% CPU. It presents as a frozen window, not a crash, so it
leaves **no `.ips` crash report** — the only evidence is a live `sample`, a
system `.hang`/spindump (`/Library/Logs/DiagnosticReports/casper_*.hang`), or an
in-app watchdog dump (`~/Library/Logs/Casper/hang-<timestamp>.txt`, see
[[hang-dump-watchdog]]).

**Why:** every fix attempted from a size-based reading of a dump has left the
hang in place. The measured signature below is what separates the actual cycle
from the costs that ride along with it; without it a session re-chases
explanations that the measurements already rule out.

**How to apply:** read the frame counts against the signature before proposing
anything, and treat a fix as unconfirmed until a live instance runs clean.

## Measured signature

Captured live on 2026-07-30 (build 804, samples archived at
`~/Library/Logs/Casper/hang-20260730-manual-{A,B}.txt`): process state `R`, 20
minutes of CPU accumulated and still climbing, on a diff of **9 files / 171
changed lines / longest line 122 characters**.

`GraphHost.flushTransactions()` never drains. It alternates between:

- **2034 of 2157** main-thread samples — a full layout pass
  (`AG::Subgraph::update` → `LazySubviewPlacements.placeSubviews`);
- **123 of 2157** — `LazyLayoutCacheItem.AllItemsPhaseMutation.apply` →
  `LazyLayoutViewCache.updateItemPhases()` → `AG::Graph::value_set` →
  `propagate_dirty`.

Each side re-dirties what the other just computed: the lazy stack's item-phase
mutation invalidates layout, layout re-runs, and re-running flips the item
phases again. At that diff size no cap in the renderer is anywhere near its
limit, so **diff size is not the trigger** and no size-based cap can be the
remedy.

## `explicitAlignment` frames are a cost multiplier, not a cycle

A high `explicitAlignment` frame count does **not** imply an explicit
`.alignmentGuide`. Implicit minor-axis guide reads produce the same frames: a
`VStack(alignment: .leading)` querying `ViewDimensions[.leading]` on an `HStack`
child forces a full nested placement of that child — `StackLayout.resize` →
`ViewDimensions.subscript.getter` → `LayoutEngineBox.explicitAlignment` →
`_HStackLayout.explicitAlignment` → nested `placeChildren` →
`StyledTextLayoutEngine` / `NSAttributedString.MetricsCache`. That accounts for
the 952 `explicitAlignment` frames in the 2026-07-30 sample. It multiplies the
cost of each pass; it does not create the loop.

## Reasoning over a dump is not verification

Four fixes in this family share one pattern — each rests on reasoning over a
dump, and none resolves the hang: a long single-line cap, refresh dedup plus
animation disabling, per-row layout caps, and removing a baseline alignment
guide from the pinned file header. A chain read out of a stack trace is a
hypothesis; only a live reproduction that stops reproducing settles it.

## Diagnostic recipe

1. `ps -o %cpu,state -p <pid>` — state `R` near 100% means a spin, not a
   deadlock.
2. `sample <pid> 3 -file /tmp/casper-sample.txt`, twice, a few minutes apart. A
   stable-or-growing count across both samples means it is not converging. A 3 s
   sample suffices: the main thread is busy, not waiting.
3. Count the discriminating frames:
   - `GraphHost.flushTransactions` with `updateItemPhases` / `propagate_dirty`
     present → the non-converging layout cycle above.
   - `StyledTextLayoutEngine` / `NSAttributedString.MetricsCache` dominant →
     text-metrics cost, bounded by the `DiffLineStyle` caps.
   - `explicitAlignment` dominant → nested guide resolution; read it as an
     amplifier alongside the other two, never on its own.

   Fewer than ~10 frames of a marker is background noise, not the driver.
4. `refresh()` logs one `.notice` per refresh (`diff refresh: files=…
   lines=… maxFileLines=… maxLineLen=… computeMs=…`) via `CasperLog.app`. Read
   it with
   `log show --predicate 'subsystem == "com.github.alexandreroman.casper"'
   --info --debug`. A flood of these with unchanged `files=`/`lines=` is the
   churn signature. Release builds often persist nothing, so treat an empty
   result as no evidence rather than as absence of churn.

Watchdog dumps whose main thread sits in `mach_msg_trap` capture a different
phenomenon and are not this hang.

## What the diff view renders through

The diff is **one TextKit 2 text document** hosted in an `NSTextView` behind an
`NSViewRepresentable`: no `LazyVStack`, no pinned `Section`, no
`.scrollPosition` binding, and no per-line SwiftUI view. The lazy-stack
item-phase machinery the cycle runs on has no substrate there, and the scroll
view negotiates nothing with SwiftUI. See [[diff-surface-data-flow]] for how a
document reaches the surface without writing state during layout, and
[[textkit2-layout-geometry]] for the fragment-geometry facts the per-line chrome
depends on.

## Only a live session confirms a fix

The hang does not reproduce headlessly: an unbundled debug binary's window counts
as not-visible, so `applyWatcherVisibility` stops the FSEvents watchers and no
refresh ever fires — see [[agent-visual-verification-limits]]. There is no
automated layout-convergence guard, and the headless fragment-geometry smoke
tests are not one. Confirming any candidate fix therefore takes a visible real
instance left open on an actively-edited worktree with the diff panel showing.
