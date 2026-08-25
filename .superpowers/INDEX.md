# Casper — Documentation Index

Theme-oriented design docs under `.superpowers/`. Durable project facts live in
`.claude/project-memory/`; implementation progress lives in
[`status.md`](status.md).

Layout:

- [`architecture.md`](architecture.md) — cross-cutting foundation
- `themes/` — one doc per area: the **authoritative** design *and* as-built
  behaviour

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

There is no `plans/` directory, and its absence is the design.

A plan is a forward-looking document: it exists while its work is still ahead.
Once the work ships, its design belongs in `architecture.md` + `themes/` and its
one-off findings in `.claude/project-memory/` — the places a reader already
looks. A shipped plan kept as a container for the few facts nobody relocated is
the worst of both: it is not where anyone searches, and nothing signals when it
starts describing an app that no longer exists.

So when a plan's work lands, absorb it and delete it. If something in it has no
obvious home, that is a gap in the themes or the memory notes to be filled, not
a reason to keep the plan. New plans are welcome — for work that has not
happened yet.

The agent-plugin repository these docs refer to is **`casper-skills`**. It
ships the `casper` plugin for all three supported agents: Claude Code and Codex
register it as `casper@casper` (plugin `casper`, marketplace `casper`), and
opencode pulls it as the npm package `casper-skills`.

Design specs for work that has fully landed are recoverable from Git history
(tracked under the now-removed `docs/superpowers/` and `.superpowers/plans/`
trees before being distilled into `architecture.md` + `themes/`).
