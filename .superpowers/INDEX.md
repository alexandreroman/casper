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

| Theme                                              | Doc                                                                  |
| -------------------------------------------------- | -------------------------------------------------------------------- |
| Core (CasperCore)                                  | [`themes/core.md`](themes/core.md)                                   |
| Git & worktrees (CasperGit)                        | [`themes/git-worktrees.md`](themes/git-worktrees.md)                 |
| CLI & agent environment (CasperCLI + CasperAgents) | [`themes/cli-agents.md`](themes/cli-agents.md)                       |
| Terminal embedding (CasperGhostty)                 | [`themes/terminal.md`](themes/terminal.md)                           |
| App & UI (CasperUI)                                | [`themes/app-ui.md`](themes/app-ui.md)                               |
| Agent state detection                              | [`themes/agent-state-detection.md`](themes/agent-state-detection.md) |
| Debug & observability                              | [`themes/debug.md`](themes/debug.md)                                 |
| Space (project)                                    | [`themes/space-project.md`](themes/space-project.md)                 |

Per-theme status markers appear in each doc's header; the authoritative
aggregate is [`status.md`](status.md).

## Plans

- [`plans/stop-hook-explicit-done.md`](plans/stop-hook-explicit-done.md) —
  `Stop` hook reports `done` explicitly instead of `idle`, since every
  hook-driven workspace is permanently under `explicitAuthority` and never gets
  a detected `done`; selecting a `done` workspace collapses it back to `idle`
  (**partly shipped** — the Casper-side collapse is built, the `casper-skills`
  hook is not).
- [`plans/notification-idle-best-practices.md`](plans/notification-idle-best-practices.md)
  — stop notifying on ordinary idle/turn-end events; only `blocked` and unseen
  `done` should raise a notification (**shipped** — spans this repo and
  `casper-skills`).
- [`plans/space-project.md`](plans/space-project.md) — Space + workspace diff
  summary (**superseded 2026-07-06**: model landed in UI-2; the diff summary is
  dropped). Kept for reference only.
- [`plans/close-inspector.md`](plans/close-inspector.md) +
  [`plans/close-inspector-plan.md`](plans/close-inspector-plan.md) — `casper
  browser close` / `diff close` CLI verbs (**shipped**).
- [`plans/diff-view-claude-code-colors.md`](plans/diff-view-claude-code-colors.md)
  + [`plans/diff-view-claude-code-colors-plan.md`](plans/diff-view-claude-code-colors-plan.md)
    — diff view restyled to match Claude Code's colors, via HighlightSwift +
    `DiffHighlighter.swift` (**shipped**).
- [`plans/github-release.md`](plans/github-release.md) — GitHub release workflow
  publishing a downloadable `Casper.app` (`.github/workflows/release.yml`)
  (**shipped**).
- [`plans/sparkle-auto-update.md`](plans/sparkle-auto-update.md) — in-app
  auto-update via Sparkle, anchored on an EdDSA-signed appcast because Casper
  ships ad-hoc signed (**shipped**).
- [`plans/screenshot-capture-permissions.md`](plans/screenshot-capture-permissions.md)
  — `make build` assembles a signed `Casper-dev.app` so the `debug-casper`
  skill's Screen Recording grant survives rebuilds (**shipped**).
- [`plans/workspace-close-selection.md`](plans/workspace-close-selection.md) + [`plans/workspace-close-selection-plan.md`](plans/workspace-close-selection-plan.md)
  — closing/deleting/merging a workspace reselects a sibling in the same Space
  first, falling back to the first workspace of the first remaining Space
  (**shipped**).
- [`plans/app-icon-composer.md`](plans/app-icon-composer.md) +
  [`plans/app-icon-composer-plan.md`](plans/app-icon-composer-plan.md) — macOS
  26 Liquid Glass `AppIcon.icon` compiled to `Assets.car` by `actool` during
  `make bundle`, alongside the legacy `.icns` (**shipped**).
- [`plans/open-in-editor.md`](plans/open-in-editor.md) +
  [`plans/open-in-editor-plan.md`](plans/open-in-editor-plan.md) — title-bar
  split-button launching the worktree in VS Code / IntelliJ IDEA / Xcode, with a
  per-workspace `lastUsedEditor` (**shipped**).
- [`plans/run-close-on-success.md`](plans/run-close-on-success.md) — a named
  `.casper.json` command's split closes on exit 0 and stays open with a live
  shell on failure (**shipped**).
- [`plans/terminal-font-size-persistence.md`](plans/terminal-font-size-persistence.md)
  + [`plans/terminal-font-size-persistence-plan.md`](plans/terminal-font-size-persistence-plan.md)
    — per-surface terminal font size persisted as `Surface.fontSize` and
    reapplied on restore (**shipped**).
- [`plans/stop-hook-explicit-done-plan.md`](plans/stop-hook-explicit-done-plan.md)
  — task-by-task companion to `stop-hook-explicit-done.md`; the Casper-side half
  (selecting a `done` workspace collapses it to `idle`) has **shipped**, the
  `casper-skills` `hooks/stop.sh` half has not.

The agent-plugin repository these plans refer to is `casper-skills`; older plan
text under `plans/` still calls it `casper-claude-plugin`. It ships the `casper`
plugin for all three supported agents: Claude Code and Codex register it as
`casper@casper` (plugin `casper`, marketplace `casper`), and opencode pulls it
as the npm package `casper-skills`.

Completed plans are marked done in place here until they are cleaned up; the
original design specs are recoverable from Git history (tracked under the
now-removed `docs/superpowers/` tree before being distilled into
`architecture.md` + `themes/`).
