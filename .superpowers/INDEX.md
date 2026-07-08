# Casper — Documentation Index

Theme-oriented design docs under `.superpowers/`. Durable project facts live in
`.claude/project-memory/`; implementation progress lives in
[`status.md`](status.md).

Layout:

- [`architecture.md`](architecture.md) — cross-cutting foundation
- `themes/` — one merged doc per area (design + as-built status)
- `plans/` — implementation plans (active and shipped, marked in place)

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
| Agent state detection | [`themes/agent-state-detection.md`](themes/agent-state-detection.md) |
| Debug & observability | [`themes/debug.md`](themes/debug.md) |
| Space (project) | [`themes/space-project.md`](themes/space-project.md) |

Per-theme status markers appear in each doc's header; the authoritative aggregate
is [`status.md`](status.md).

## Plans

- [`plans/notification-idle-best-practices.md`](plans/notification-idle-best-practices.md)
  — stop notifying on ordinary idle/turn-end events; only `blocked` and unseen
  `done` should raise a notification (**draft** — spans this repo and
  `casper-claude-plugin`).
- [`plans/space-project.md`](plans/space-project.md) — Space + workspace diff
  summary (**superseded 2026-07-06**: model landed in UI-2; the diff summary is
  dropped). Kept for reference only.
- [`plans/close-inspector.md`](plans/close-inspector.md) +
  [`plans/close-inspector-plan.md`](plans/close-inspector-plan.md) — `casper
  browser close` / `diff close` CLI verbs (**shipped**).
- [`plans/diff-view-claude-code-colors.md`](plans/diff-view-claude-code-colors.md) +
  [`plans/diff-view-claude-code-colors-plan.md`](plans/diff-view-claude-code-colors-plan.md)
  — diff view restyled to match Claude Code's colors, via HighlightSwift +
  `DiffHighlighter.swift` (**shipped**).
- [`plans/github-release.md`](plans/github-release.md) — GitHub release workflow
  publishing a downloadable `Casper.app` (`.github/workflows/release.yml`)
  (**shipped**).

Completed plans are marked done in place here until they are cleaned up; the
original design specs are recoverable from Git history (tracked under the
now-removed `docs/superpowers/` tree before being distilled into
`architecture.md` + `themes/`).
