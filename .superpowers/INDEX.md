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

Each entry below says what it carries that exists nowhere else — a plan with no
such answer has been deleted.

- [`plans/sparkle-auto-update.md`](plans/sparkle-auto-update.md) — in-app
  auto-update via Sparkle, anchored on an EdDSA-signed appcast because Casper
  ships ad-hoc signed. Carries the **EdDSA key rotation procedure**: Sparkle
  rotates a key but never removes one, so losing the seed strands every
  installed copy. Recorded nowhere else, and `release.yml` prints this path
  when signing fails.
- [`plans/screenshot-capture-permissions.md`](plans/screenshot-capture-permissions.md)
  — `make build` assembles a signed `Casper-dev.app` so the `debug-casper`
  skill's Screen Recording grant survives rebuilds. Carries **why the `.app`
  wrapper is mandatory** — a loose Mach-O binary never registers with TCC at
  all — and is cited twice by the `Makefile` for the certificate setup.
- [`plans/terminal-font-size-persistence.md`](plans/terminal-font-size-persistence.md)
  — per-surface terminal font size persisted as `Surface.fontSize`. Carries the
  spike result the capture mechanism rests on (whether
  `ghostty_surface_inherited_config` echoes a *live* runtime font size) and the
  rejected `ghostty_surface_update_config` alternative; cited by
  `Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift`.

The agent-plugin repository these plans refer to is **`casper-skills`**. It
ships the `casper` plugin for all three supported agents: Claude Code and Codex
register it as `casper@casper` (plugin `casper`, marketplace `casper`), and
opencode pulls it as the npm package `casper-skills`.

Design specs for work that has fully landed are recoverable from Git history
(tracked under the now-removed `docs/superpowers/` tree before being distilled
into `architecture.md` + `themes/`, and under `plans/` before being deleted).
