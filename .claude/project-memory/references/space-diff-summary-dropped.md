---
name: "Per-workspace diff summary is dropped"
description: "The Space +/− branch-vs-merge-base per-row diff summary is not built and will not be; the title-bar summary covers the need"
type: project
---

# Per-workspace diff summary is dropped

The per-workspace `+/−` **branch-vs-merge-base** diff summary (a divergence
badge on each sidebar workspace row) is **not built** and will not be:
`Repository.divergenceLineStats` and `WorktreeManager.diffStat` are not to be
implemented; the Space theme's model / remote / naming tasks
(`.superpowers/themes/space-project.md`) are already delivered under CasperUI
UI-2.

**Why:** the title-bar working-tree-vs-HEAD diff summary (`DiffService` via
`computeDiff`/`diffWorkdirToHead`) already covers the practical need, so the
extra branch-divergence variant is not worth building.

**How to apply:** do not propose or start the diff-summary / divergence-stats
work. `.superpowers/themes/space-project.md` and `.superpowers/status.md` carry
the Space theme's remaining scope.
