# Casper — Documentation Index

Theme-oriented design docs under `.superpowers/`. Durable project facts live in
`.claude/project-memory/`; implementation progress lives in
[`status.md`](status.md).

Layout:

- [`architecture.md`](architecture.md) — cross-cutting foundation
- `themes/` — one merged doc per area (design + as-built status)
- `plans/` — active (unbuilt) implementation plans

## Foundation

- [`architecture.md`](architecture.md) — vision, hard constraints, locked
  decisions, module boundaries, canonical data model, risks, testing, v1 scope.

## Themes

| Theme | Doc |
| --- | --- |
| Core (CasperCore) | [`themes/core.md`](themes/core.md) |
| Git & worktrees (CasperGit) | [`themes/git-worktrees.md`](themes/git-worktrees.md) |
| CLI & agent hooks (CasperCLI + CasperAgents) | [`themes/cli-agents.md`](themes/cli-agents.md) |
| Terminal embedding (CasperGhostty) | [`themes/terminal.md`](themes/terminal.md) |
| App & UI (CasperUI) | [`themes/app-ui.md`](themes/app-ui.md) |
| Debug & observability | [`themes/debug.md`](themes/debug.md) |
| Space (project) & diff summary | [`themes/space-project.md`](themes/space-project.md) |

Per-theme status markers appear in each doc's header; the authoritative aggregate
is [`status.md`](status.md).

## Active plans

- [`plans/space-project.md`](plans/space-project.md) — Space + workspace diff
  summary (unbuilt).
- *CasperUI / app — plan not written yet (the current milestone).*

The original design specs and completed build plans are not kept here — they are
recoverable from Git history (tracked under `docs/superpowers/` before being
distilled into `architecture.md` + `themes/`).
