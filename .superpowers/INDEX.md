# Casper — Documentation Index

Theme-oriented design docs under `.superpowers/`. Durable project facts live in
`.claude/project-memory/`; implementation progress lives in
[`status.md`](status.md).

Layout:

- [`architecture.md`](architecture.md) — cross-cutting foundation
- `themes/` — one doc per area: the **authoritative** design *and* as-built
  behaviour
- `plans/` — implementation plans still worth keeping (see § Plans)

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

**Ownership.** The themes own design *and* as-built behaviour — how a thing
works is described there, once. [`status.md`](status.md) is the progress
ledger: what is built, what is not, what was decided against, and links into the
themes for the detail. When the two disagree, the theme wins.

Per-theme status markers appear in each doc's header.

## Plans

`plans/` holds design docs for work whose rationale is not recoverable from the
themes, the code or Git history. A plan whose content has been absorbed into
`architecture.md` + `themes/` is deleted rather than kept marked "shipped" — the
themes are the design source of truth, and a stale plan is worse than no plan.

- [`plans/stop-hook-explicit-done.md`](plans/stop-hook-explicit-done.md) +
  [`plans/stop-hook-explicit-done-plan.md`](plans/stop-hook-explicit-done-plan.md)
  — the `Stop` hook reports `done` explicitly instead of `idle`, since every
  hook-driven workspace is permanently under `explicitAuthority` and never gets
  a detected `done`; selecting a `done` workspace collapses it back to `idle`
  (**partly shipped** — the Casper-side collapse is built, the `casper-skills`
  hook is not).
- [`plans/notification-idle-best-practices.md`](plans/notification-idle-best-practices.md)
  — stop notifying on ordinary idle/turn-end events; only `blocked` and unseen
  `done` should raise a notification (**shipped** — spans this repo and
  `casper-skills`).
- [`plans/run-close-on-success.md`](plans/run-close-on-success.md) — a named
  `.casper.json` command's split closes on exit 0 and stays open with a live
  shell on failure (**shipped**).
- [`plans/github-release.md`](plans/github-release.md) — GitHub release workflow
  publishing a downloadable `Casper.app` (`.github/workflows/release.yml`)
  (**shipped**).
- [`plans/sparkle-auto-update.md`](plans/sparkle-auto-update.md) — in-app
  auto-update via Sparkle, anchored on an EdDSA-signed appcast because Casper
  ships ad-hoc signed. Carries the **EdDSA key rotation procedure**, which is
  recorded nowhere else, and is cited by `.github/workflows/release.yml`
  (**shipped**).
- [`plans/screenshot-capture-permissions.md`](plans/screenshot-capture-permissions.md)
  — `make build` assembles a signed `Casper-dev.app` so the `debug-casper`
  skill's Screen Recording grant survives rebuilds. Cited by the `Makefile` for
  the Apple Development certificate setup (**shipped**).
- [`plans/workspace-close-selection.md`](plans/workspace-close-selection.md) —
  closing, deleting or merging a workspace reselects a sibling in the same Space
  first, falling back to the first workspace of the first remaining Space
  (**shipped**).
- [`plans/app-icon-composer.md`](plans/app-icon-composer.md) — the macOS 26
  Liquid Glass `AppIcon.icon`, compiled to `Assets.car` by `actool` during
  `make bundle` alongside the legacy `.icns` (**shipped**).
- [`plans/terminal-font-size-persistence.md`](plans/terminal-font-size-persistence.md)
  — per-surface terminal font size persisted as `Surface.fontSize` and reapplied
  on restore (**shipped**).

The agent-plugin repository these plans refer to is **`casper-skills`**. It
ships the `casper` plugin for all three supported agents: Claude Code and Codex
register it as `casper@casper` (plugin `casper`, marketplace `casper`), and
opencode pulls it as the npm package `casper-skills`.

Design specs for work that has fully landed are recoverable from Git history
(tracked under the now-removed `docs/superpowers/` tree before being distilled
into `architecture.md` + `themes/`, and under `plans/` before being deleted).
