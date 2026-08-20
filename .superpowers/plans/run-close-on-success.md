# Auto-Close a `casper run` Terminal on Success — Design

**Date:** 2026-07-15
**Status:** Shipped
**Scope:** A terminal opened by `casper run <script>` should disappear from the
workspace layout when the script succeeds (exit code 0). On failure (any
non-zero exit) the terminal stays open with a live interactive shell, its error
output visible above the prompt, so the user can inspect or re-run.

## Problem

`casper run <name>` opens a new terminal split and injects the resolved command
into the interactive shell, wrapped by `subshellWrappedScriptCommand`
(`AppModel.swift:2091`), which today produces:

```bash
(
<command>
)
```

The subshell exists so a script that calls `exit` (or fails under `set -e`)
terminates only the subshell — the interactive shell survives and the pane
stays open **regardless of the exit code**. That is the current behavior: a
`casper run` terminal never auto-closes; the user must close it manually.

The desired behavior is the same one the **setup** lifecycle hook already has
(close on success, keep on failure), but `casper run` surfaces are not wired to
it: they are created via `controlOpenTerminal` and are never registered in
`scriptSurfaces`, so `handleScriptSurfaceExit` (`AppModel.swift:2000`) is a
no-op for them.

## Goals

- A `casper run` script that exits `0` closes its terminal: the pane is pruned
  from the layout automatically.
- A `casper run` script that exits non-zero leaves the terminal open with a
  **live, interactive shell** — the error output stays visible and the user can
  type further commands.
- A script that calls `exit N` internally is captured by the subshell, so
  `exit 1` inside the script keeps the terminal open (it does not kill the
  interactive shell directly).
- Always on: no configuration flag. Every `casper run` terminal behaves this
  way.

## Non-Goals

- No change to the setup/teardown lifecycle hooks (`hookWrappedScriptCommand`,
  `handleScriptSurfaceExit`, `scriptSurfaces`) — untouched.
- No new exit-code correlation for `casper run`: we do **not** register these
  surfaces in `scriptSurfaces` or add new Swift state. The close is driven by
  the existing `close_surface_cb` path (the same one that closes a pane when the
  user types `exit`).
- No `.casper.json` schema change, no new CLI verb, no control-channel change.
- No change to terminals opened by any means other than `casper run`
  (`controlOpenTerminal` with no command, toolbar/keyboard new-terminal, etc.).

## Design

### The one-line wrapper change

`subshellWrappedScriptCommand` (`AppModel.swift:2091`) changes from:

```swift
static func subshellWrappedScriptCommand(_ command: String) -> String {
    "(\n\(command)\n)"
}
```

to append a conditional exit after the subshell:

```swift
static func subshellWrappedScriptCommand(_ command: String) -> String {
    "(\n\(command)\n)\n[ $? -eq 0 ] && exit"
}
```

producing:

```bash
(
<command>
)
[ $? -eq 0 ] && exit
```

The command still sits on its own line between newlines so a trailing `#`
comment cannot swallow the closing paren, and the `[ … ]` test sits on its own
line after `)` so the same comment cannot swallow it either.

### Why this works

- `$?` after the subshell holds the subshell's exit status, which is the status
  of the script's last command — or the code of an `exit N` the script ran
  inside the subshell. Either way it is "did the script succeed."
- **Success** (`$?` == 0): the test succeeds, `&& exit` runs, the interactive
  shell exits. libghostty detects the child process exit and fires
  `close_surface_cb` (`GhosttyRuntime.swift:348`) → `view.requestClose()` →
  `onClose` → `applyCloseSurface` (`AppModel.swift:1082`), which prunes the pane
  from the layout via `LayoutTree.closeSurface`. This is the exact path already
  used when a user types `exit` in any terminal.
- **Failure** (`$?` != 0): the test fails (`[ … ]` returns status 1), `&& exit`
  short-circuits, `exit` never runs. The interactive shell stays alive at a
  prompt with the subshell's output scrolled above.

`POSIX` `[ $? -eq 0 ]` is safe across `sh`/`bash`/`zsh`. The wrapper is injected
as typed text (`pendingInitialInput` → `initialInput`, `AppModel.swift:1174`),
exactly as today; only the text changes.

### `close_surface_cb` does not need to distinguish these surfaces

`casper run` surfaces are not registered in `scriptSurfaces`, so on the success
exit both signals fire harmlessly:

- `GHOSTTY_ACTION_SHOW_CHILD_EXITED` → `onChildExit` → `handleScriptSurfaceExit`,
  which returns immediately (`guard scriptSurfaces[id]` fails) — a no-op.
- `close_surface_cb` → `applyCloseSurface`, which prunes the pane. The
  lifecycle-hook guards in `applyCloseSurface` (`keptFailedSetupSurfaces`,
  `pendingTeardownPrunes`) key off state that a plain `casper run` surface never
  populates, so they do not apply and the pane closes normally.

**Verification point (implementation):** confirm `applyCloseSurface` has no
guard that blocks closing an unregistered surface arriving via
`close_surface_cb`. Expected: none — the guards target setup/teardown only.

### Doc-comment update

The comment above `subshellWrappedScriptCommand` (`AppModel.swift:2085-2090`)
currently states the subshell keeps the pane open. Rewrite it to describe the
new contract: subshell isolates the script's `exit`/`set -e` from the
interactive shell, then the shell exits (closing the pane) only when the script
succeeded; a failing script leaves the interactive shell alive.

## Trade-off (accepted)

A fast-succeeding script makes the pane "flash": it opens and then closes almost
immediately, and its success output is not retained. This is the requested
behavior (systematic close on success). Long-running successful commands (e.g. a
dev server) never exit, so they simply stay open as before.

## Testing

- `Tests/CasperUITests/ControlHandlerTests.swift:702-704` — update the expected
  output of `subshellWrappedScriptCommand`:
  - `subshellWrappedScriptCommand("exit 1")` → `"(\nexit 1\n)\n[ $? -eq 0 ] && exit"`
  - `subshellWrappedScriptCommand("npm test # smoke")` →
    `"(\nnpm test # smoke\n)\n[ $? -eq 0 ] && exit"`
  - Assert `hookWrappedScriptCommand` is unchanged (regression guard that the
    two wrappers stay distinct).
- Manual verification via `make dev` + the `debug-casper` skill, in a workspace
  with a `.casper.json` defining two scripts:
  - A succeeding script (e.g. `run: "true"`): `casper run run` opens a split
    that closes on its own within a moment; confirm the layout returns to its
    prior shape.
  - A failing script (e.g. `fail: "false"` or `fail: "echo boom; exit 3"`):
    `casper run fail` opens a split that **stays**, shows the output, and offers
    a live interactive prompt (typing `echo hi` works).
  - A script that calls `exit 1` internally: confirm the terminal stays open
    (the subshell captures the exit; the interactive shell survives).

## Affected files

- `Sources/CasperUI/AppModel.swift` — `subshellWrappedScriptCommand` body +
  its doc comment.
- `Tests/CasperUITests/ControlHandlerTests.swift` — updated expectations.
- Docs describing `casper run` behavior (e.g. the `casper-config` skill or
  README) if they state that the run terminal stays open — align them with the
  new close-on-success contract.
