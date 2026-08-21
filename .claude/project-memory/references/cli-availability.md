---
name: cli-availability
description: "No global `casper` install; the binary is reachable only inside Casper-opened terminals via PATH injection"
type: feedback
---

# cli-availability

The `casper` CLI is **not** installed globally: there is no `~/.local/bin/casper`
shim. `casper` only needs to be reachable inside terminals Casper opens, so
Casper **prepends its own binary's directory to `PATH`** in every terminal
surface's environment. This is why a bare `casper status set running` (or any
domain command — see [[domain-cli-control-channel]]) resolves inside a Casper
terminal but nowhere else on the system.

**Why:** the CLI need not exist on the general system, only inside a terminal
Casper opens. PATH injection (rather than an absolute path anywhere) keeps
`casper` literally available only in Casper terminals, so nothing pollutes the
rest of the system.

**How to apply:** `AgentEnvironment.surfaceEnvironment(...)` takes optional
`casperDirectory` + `basePath` and, when given, sets
`PATH = "<casperDirectory>:<basePath>"` (or just `<casperDirectory>` when
basePath is empty). The app supplies the app bundle's executable directory
(`Bundle.main.executableURL`'s parent) and the inherited `PATH`.

**The injected directory is not guaranteed to win the lookup.** The app prepends
it, but the login shell then rebuilds `PATH` from the user's profile, and a
`mise`-style tool that re-orders entries can leave another Casper bundle's
directory ahead of the injected one. Measured in a `make dev` terminal launched
from an installed-app terminal: `~/Applications/Casper.app/Contents/MacOS` at
position 22, the injected `Casper-dev.app/Contents/MacOS` at 24 — so bare
`casper` ran the **installed** binary inside the dev app's own terminal.

**Consequence when testing a branch's new CLI verbs:** a verb added on a feature
branch reads as an unknown subcommand whenever the installed build (from `main`)
wins that lookup, however green the branch's tests are. Exercise new verbs in
the `make dev` window (see [[app-sessions]]) and address the binary explicitly:
scripts use `"$GHOSTTY_BIN_DIR/casper"` — libghostty exports the bin directory of
the bundle that opened the terminal, so the script always drives the instance
displaying it — and a shell outside a Casper terminal uses the bundle path
directly (`./Casper-dev.app/Contents/MacOS/casper`).
