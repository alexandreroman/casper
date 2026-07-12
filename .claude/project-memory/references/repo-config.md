---
name: ".casper.json per-repo config — scripts (Part B) status & remaining design"
description: "Part A + B1/B2/B2-UI shipped; setup/teardown hooks still to build, with settled design"
type: project
---

# .casper.json per-repo config — scripts (Part B) status & remaining design

`.casper.json` at a Git repo root is the per-repository config, grouped by
domain under a `workspace` key. Design specs live in gitignored
`.superpowers/sdd/` (`2026-07-12-*-scripts-design.md` / `*-plan.md`), which
does not persist — this note is the durable record for resuming. Progress ledger:
`.superpowers/sdd/progress.md` (gitignored).

## Shipped on branch `casper-json`

- **Part A** — `workspace.copyPatterns` drives which untracked files seed a new
  worktree. `RepoConfig` (CasperCore); replace-not-merge semantics; invalid file
  fails workspace creation with `Invalid .casper.json: <reason>`.
- **B1** — `workspace.scripts` schema (`[String: String]`) + helpers:
  `RepoScripts.reservedNames == {setup, teardown}`, `RepoConfig.setupScript()`,
  `teardownScript()`, `namedCommand(_:)` (nil for reserved/empty),
  `namedCommands()` (non-reserved, sorted), `RepoNamedCommand`.
- **B2 (CLI)** — `casper run [name]` (defaults to `run`) runs a named command in
  a visible terminal. `ControlCommand.Verb.run` + `name` field;
  `RepoConfig.resolveRunCommand(_:) -> RunResolution{.command,.denied}` (pure,
  refuses reserved/unknown names, lists available); `AppModel.controlRun`;
  `ControlServer` `.run` dispatch. Config read from the workspace's own
  `worktreePath`.
- **B2-UI** — named-command UI, both surfaces hidden when none defined:
  - `Workspace.lastUsedScript: String?` (persisted).
  - `AppModel`: `@ObservationIgnored` `namedCommandsCache` (refreshed in
    `selectWorkspace`, pruned in `removeWorkspace`), `namedCommands(for:)`
    (cached/lazy), `resolvedScript(for:)` (last-used → `run` → first alphabetical),
    `runScript(_:for:)` (via `controlRun`, remembers last-used, sets observable
    `scriptRunError` on failure — mirrors `editorLaunchError`).
  - Toolbar split-button in `WorkspaceDetailView` mirroring `editorButton`; and a
    "Run Script ▸" submenu on the sidebar workspace context menu (`SidebarView`).
  - Verified live: `casper run`/`run test` open splits; `run setup` refused;
    `run bogus` lists available; script labels show `displayName` (key with `-`/`_`
    → spaces, capitalized, e.g. `build-app` → `Build App`); `casper run` commands
    run in a subshell `(\n<cmd>\n)` so a script `exit` keeps the terminal open.
  - **Script order is NOT file order.** `workspace.scripts` is a JSON object
    (`[String: String]`), and Swift's `JSONDecoder` does not preserve object key
    order (proven: `allKeys` returns hash order, not document order). The menu is
    therefore **alphabetical** (`namedCommands()` sorts). File-order would require
    reformatting `scripts` to an array `[{name, command}]` — deliberately NOT done.
    Default selected script (toolbar primary button) = remembered `lastUsedScript`
    → `run` if present → first alphabetical.

## Remaining phases (settled design, NOT yet built)

- **B3 — setup hook** — exit-code wiring first: intercept
  `GHOSTTY_ACTION_SHOW_CHILD_EXITED` surface-scoped in `casperGhosttyAction`
  (recover the view via `surfaceView(from:target)`, read
  `action.action.child_exited.exit_code`), add `onChildExit(UUID, Int32)` to
  `GhosttySurfaceView` (mirror `onClose`), wire in `AppModel.surfaceView`. Then a
  script-surface controller runs `setup` (wrapped `<cmd>; exit $?`) in a visible
  split from `createLinkedWorkspace` ONLY (never on restore). It must correlate
  TWO libghostty events per script surface: `close_surface_cb`→`onClose` (which
  today always closes the pane) and the exit code. Exit 0 → close the split;
  exit ≠ 0 → intercept the auto-close, keep the split showing the error, mark the
  workspace error state; no rollback.
- **B4 — teardown hook (riskiest)** — restructure the 3 destroy entry points
  (`deleteWorkspace`, `controlDeleteWorkspace`, `closeWorkspace`) so a `teardown`
  script runs in a visible split before `pruneWorkspaceFromDisk` (after the merge
  on the close path), waiting for child-exit or a 30 s timeout; then prune
  regardless of outcome (signal failures). Control-channel delete replies after
  prune completes.

## Loose ends to close at Part B end

- Harden `casper run` CLI: guard on missing terminal in the response (mirror
  `TerminalCommand.New`) instead of the current `?? ""` fallback.
- Document `casper run` in `README.md`.
- Commit the `.claude/project-memory/` files (currently uncommitted).

## Gotcha when live-testing on a dev machine

The user's zsh profile puts the installed release `~/Applications/Casper.app`
ahead of the branch's `Casper-dev.app` in PATH, so a bare `casper` in a Casper
terminal runs the OLD release (no `run`). Test with the full dev-binary path or
a temporary alias. The debug channel (`casper debug`) only enumerates terminal
surfaces, not SwiftUI toolbar/menu chrome — UI must be verified by a human.

**Why:** SwiftUI + libghostty phases need human visual verification, so work is
staged; user paused after B2-UI to verify the Run Script button and review.

**How to apply:** resume from the B3 / B4 sections above; the shipped B1 helpers
and B2 `controlRun`/terminal machinery are the building blocks.
