---
name: "SDD design and plan document location"
description: "New brainstorm/design/plan docs go in .superpowers/sdd/ (gitignored), not docs/superpowers/specs/"
type: feedback
---

# SDD design and plan document location

New SDD design and plan documents go in `.superpowers/sdd/`, not in
`docs/superpowers/specs/`. This overrides the superpowers `brainstorming` skill's
default location of `docs/superpowers/specs/`.

**Why:** `.superpowers/sdd/` is the active scratch directory where every recent
design/plan pair lives (e.g. `native-sidebar`, `sidebar-ui-rework`,
`casper-ui-1..5`, `casper-git-diff`, `keyboard-shortcuts`). It is gitignored
(`.gitignore` line 17 plus `.superpowers/sdd/.gitignore`), so these docs are never
committed and need no commit authorization. The `docs/superpowers/` tree (the
`brainstorming` skill's default location) has been **removed** from the repo; its
old specs are recoverable only from Git history, distilled into
`.superpowers/architecture.md` + `.superpowers/themes/`. Do not recreate it.

**How to apply:** write brainstorm outputs to
`.superpowers/sdd/YYYY-MM-DD-<topic>-design.md` and plans to
`.superpowers/sdd/YYYY-MM-DD-<topic>-plan.md`. Do not commit them. Keep the
authoritative distilled design in `.superpowers/architecture.md` + `themes/` and
durable facts in `.claude/project-memory/`.
