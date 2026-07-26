---
name: "Per-workspace diff summary is dropped"
description: "The Space +/− branch-vs-merge-base per-row diff summary is not built; only Space rename remains open for the Space theme"
type: project
---

# Per-workspace diff summary is dropped

The per-workspace `+/−` **branch-vs-merge-base** diff summary (a divergence badge
on each sidebar workspace row) is **not built** and will not be:
`Repository.divergenceLineStats` and `WorktreeManager.diffStat` are not to be
implemented, and `plans/space-project.md` is superseded (its model / remote /
naming tasks are already delivered under CasperUI UI-2).

The Space theme's only remaining open item is **Space rename**.

**Why:** the title-bar working-tree-vs-HEAD diff summary (`DiffService` via
`computeDiff`/`diffWorkdirToHead`) already covers the practical need, so the
extra branch-divergence variant is not worth building.

**How to apply:** do not propose or start the diff-summary / divergence-stats
work. If picking the "next step" for the Space theme, it is Space rename. See
`.superpowers/themes/space-project.md` and `.superpowers/status.md` (both updated
to reflect the drop).
