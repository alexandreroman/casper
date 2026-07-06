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

**How to apply:** `ClaudeCodeAdapter.surfaceEnvironment(...)` takes optional
`casperDirectory` + `basePath` and, when given, sets
`PATH = "<casperDirectory>:<basePath>"` (or just `<casperDirectory>` when
basePath is empty). The app supplies the app bundle's executable directory
(`Bundle.main.executableURL`'s parent) and the inherited `PATH`. (The removed
`casper hooks feed` relay relied on this same relative-resolution property; hook
installation is now a GUI follow-up — see [[hooks-install-once]].)
