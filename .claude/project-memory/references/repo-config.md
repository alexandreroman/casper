---
name: ".casper.json scripts — design decisions & invariants"
description: "Non-obvious design decisions behind .casper.json copyFiles + named commands + setup/teardown hooks"
type: project
---

# .casper.json scripts — design decisions & invariants

`.casper.json` at a Git repo root is the per-repository config, grouped under a
`workspace` key: `copyFiles` (untracked files seeded into a new worktree) and
`scripts` (name → shell command). This note records the durable design decisions
and rationale that are NOT obvious from the code. Implementation STATUS lives in
`.superpowers/status.md`, not here (see [[project-memory-conventions]]).

## Two kinds of scripts

- Reserved keys `setup`/`teardown` are lifecycle hooks — run automatically, never
  invocable by hand (`RepoScripts.reservedNames`; `resolveRunCommand` `.denied`s
  them; `spawnScriptSurface` is private).
- Every other key is a named command, run on demand from the UI or `casper run`.

## Hook wrap vs. named-command wrap (opposite goals)

- Named commands wrap as `subshellWrappedScriptCommand` = `"(\n<cmd>\n)"` so a
  script that `exit`s (or fails under `set -e`) kills only the subshell — the
  interactive pane stays open with the output.
- Hooks wrap as `hookWrappedScriptCommand` = `"<cmd>\nexit $?"` so the shell
  exits with the command's status, which makes libghostty emit a child-exit event
  — the completion signal a hook needs. The newline (not `;`) keeps a trailing
  `#` comment on the command's last line from swallowing `exit $?`.

## THE child-exit / close race (load-bearing invariant)

libghostty delivers the child-exit action SYNCHRONOUSLY mid-`ghostty_app_tick`,
while `close_surface_cb` DEFERS `requestClose` to the next runloop turn — so
`handleScriptSurfaceExit` always runs BEFORE the correlated pane close. Every
correctness argument in the hooks code rests on this. Corollaries, do not break:

- **Never close or prune eagerly inside a child-exit callback.** Tearing views
  down mid-tick detaches sibling panes (the exact hazard `close_surface_cb`
  defers). setup-success relies on the deferred `close_surface_cb` to close its
  split; teardown defers its continuation resume — and so the prune it triggers
  — via `DispatchQueue.main.async` (+ `MainActor`) in `finishTeardown`. Resuming
  a continuation already enqueues rather than running inline, but the explicit
  hop is what makes that guarantee independent of Swift scheduling details.
- **setup guards in `applyCloseSurface`:** a still-tagged `.setup` surface is
  never torn down by an early close (its fate is the exit code); a FAILED setup
  arms `keptFailedSetupSurfaces` to swallow the one shell-exit close so the pane
  stays open showing the error.
- This assumes libghostty emits a `close_surface_cb` after the child exits — true
  for the current pin (every shell-exit pane close relies on it). A future pin
  that suppressed it would strand a successful setup's split.

## setup / teardown behavior decisions

- **setup** runs from `createLinkedWorkspace` ONLY — the call site is the guard
  against re-running on restore/re-open, so there is no persisted "ran" flag. Exit
  0 → split auto-closes; exit ≠ 0 → split kept open + workspace flagged `.error`
  (`setDetectedAgentState`); no rollback.
- **teardown** runs before prune, AFTER the merge on the close path (the worktree
  still exists → valid cwd). Any outcome (success / non-zero / 30 s
  `teardownTimeout`) proceeds to prune — a broken cleanup script never traps the
  user. A manually-closed live teardown split prunes immediately rather than
  stalling the timeout.

## Destroy paths: async, guarded by a synchronous claim

`closeWorkspace`/`deleteWorkspace` are `async` and return their outcome.
`controlDeleteWorkspace` keeps a completion closure because
`ControlServer.handle` is reply-based: `.workspaceDelete` replies AFTER prune,
so `casper workspace delete` sends `timeout: 35` (> the 30 s app budget) or a
slow teardown reads as a client-side timeout.

Re-entrancy is rejected by claiming the workspace id in `closingWorkspaces`
**synchronously, with no `await` between the test and the insert**, released in
a `defer`. A probe sited further from the claim is NOT safe here: the git work
runs off the main actor, so any suspension point between the two lets a second
destroy pass the guard, clobber the first's continuation (permanent hang, leaked
continuation, undismissable sheet) and run concurrent libgit2 writes against one
repo — the main actor no longer serializes them.

Teardown waits are additionally scoped by a monotonic generation
(`isTeardownCurrent`). The 30 s timer is never cancelled, so without the
generation a stale timer from an abandoned run resumes a LATER run for the same
workspace with `.timedOut` — aborting a healthy hook and posting a false "timed
out" notification. Same reason the manual-close branch resumes through the
split's own `onExit` instead of calling `finishTeardown` directly.

## Script menu ordering

`workspace.scripts` is a JSON object, and Swift's `JSONDecoder` does NOT preserve
object key order (proven: `allKeys` returns hash order). The menu is therefore
**alphabetical** (`namedCommands()` sorts); file order would need reformatting
`scripts` to an array — deliberately not done. Default selected script (toolbar
primary button) = remembered `lastUsedScript` → `run` if present → first
alphabetical.

## Gotcha when live-testing on a dev machine

The user's zsh profile puts the installed release `~/Applications/Casper.app`
ahead of the branch's `Casper-dev.app` in PATH, so a bare `casper` in a Casper
terminal runs the OLD release. Test with the full dev-binary path or a temporary
alias. `casper debug` only enumerates terminal surfaces, not SwiftUI toolbar/menu
chrome, so the split lifecycle (setup auto-close/keep-open, teardown wait) must be
watched by a human — see [[agent-visual-verification-limits]].

**Why:** these are the decisions and the one hard invariant that a future change
to the hooks would most easily get wrong; none is recoverable from reading the
code alone.

**How to apply:** when touching the hooks, treat the child-exit/close race
section as a hard constraint — don't close or prune eagerly inside a child-exit
callback.
