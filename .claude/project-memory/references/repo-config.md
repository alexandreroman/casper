---
name: ".casper.json scripts — design decisions & invariants"
description: "Non-obvious design decisions behind .casper.json copyFiles + named commands + setup/teardown hooks"
type: project
---

# .casper.json scripts — design decisions & invariants

The `.casper.json` design — the two kinds of scripts, their opposite wraps, the
`setup`/`teardown` decisions and the alphabetical script menu — is in
`.superpowers/themes/cli-agents.md` § Per-repository config. This note keeps the
invariants and gotchas the theme hands off to it.

## THE child-exit / close race (load-bearing invariant)

libghostty delivers the child-exit action SYNCHRONOUSLY mid-`ghostty_app_tick`,
while `close_surface_cb` DEFERS `requestClose` to the next runloop turn — so
`handleScriptSurfaceExit` always runs BEFORE the correlated pane close. Every
correctness argument in the hooks code rests on this. Corollaries, do not break:

- **Never close or prune eagerly inside a child-exit callback.** Tearing views
  down mid-tick detaches sibling panes (the exact hazard `close_surface_cb`
  defers). setup-success relies on the deferred `close_surface_cb` to close its
  split; teardown defers its continuation resume — and so the prune it triggers
  — via `MainRunLoop.perform` in `finishTeardown` (see [[main-run-loop-hop]]).
  Resuming a continuation already enqueues rather than running inline, but the
  explicit hop is what makes that guarantee independent of Swift scheduling
  details.
- **setup guards in `applyCloseSurface`:** a still-tagged `.setup` surface is
  never torn down by an early close (its fate is the exit code); a FAILED setup
  arms `keptFailedSetupSurfaces` to swallow the one shell-exit close so the pane
  stays open showing the error. That hook state — `scriptSurfaces`,
  `keptFailedSetupSurfaces`, `pendingTeardownResumes` — is owned privately by
  `ScriptHookRunner`; `applyCloseSurface`, on `AppModel`, reaches it only
  through the runner's narrow query/consume methods. `closingWorkspaces` is the
  exception that lives on `AppModel`: it claims the whole close/delete operation
  (probes, merge, prune), not just the hook.
- This assumes libghostty emits a `close_surface_cb` after the child exits —
  true for the current pin (every shell-exit pane close relies on it). A future
  pin that suppressed it would strand a successful setup's split.

## setup / teardown runtime rules

- A manually-closed live teardown split prunes immediately rather than
  stalling the 30 s `teardownTimeout`.
- **named commands wait for setup**: while a workspace's setup is in flight,
  `controlRun` — the one gate behind the toolbar, the menus and `casper run` —
  refuses every named command. The in-flight set is the observable
  `AppModel.setupRunningWorkspaces`, written only through the runner's
  `reportSetupRunning` closure: set before the split spawns, cleared on the
  setup's child exit (any status), on a spawn failure, and in `forget`.
  teardown runs through `runTeardown`, outside that gate, so a close or delete
  mid-setup still runs it.

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
repo, which the main actor does not serialize once the work is off it.

Teardown waits are additionally scoped by a monotonic generation
(`isTeardownCurrent`). The 30 s timer is never cancelled, so without the
generation a stale timer from an abandoned run resumes a LATER run for the same
workspace with `.timedOut` — aborting a healthy hook and posting a false "timed
out" notification. Same reason the manual-close branch resumes through the
split's own `onExit` instead of calling `finishTeardown` directly.

## Default script

The toolbar's primary script button defaults to the remembered `lastUsedScript`,
then `run` if present, then the first name alphabetically.

## Gotcha when live-testing on a dev machine

A bare `casper` in a Casper terminal can resolve to an installed release build
rather than the branch's `Casper-dev.app` — address the dev binary explicitly,
per [[cli-availability]]. `casper debug` only enumerates terminal surfaces, not
SwiftUI toolbar/menu chrome, so the split lifecycle (setup auto-close/keep-open,
teardown wait) must be watched by a human — see
[[agent-visual-verification-limits]].

**Why:** these are the decisions and the one hard invariant that a future change
to the hooks would most easily get wrong; none is recoverable from reading the
code alone.

**How to apply:** when touching the hooks, treat the child-exit/close race
section as a hard constraint — don't close or prune eagerly inside a child-exit
callback.
