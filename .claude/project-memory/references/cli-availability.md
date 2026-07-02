---
name: cli-availability
description: "No global `casper` install; the binary is reachable only inside Casper-opened terminals via PATH injection"
type: feedback
---

# cli-availability

The `casper` CLI is **not** installed globally: there is no `~/.local/bin/casper`
shim. `casper` only needs to be reachable inside terminals Casper opens, so
Casper **prepends its own binary's directory to `PATH`** in every terminal
surface's environment. The global `~/.claude/settings.json` keeps the *relative*
hook command `casper hooks feed`, which therefore resolves only within Casper's
terminals — nowhere else on the system.

**Why:** the CLI need not exist on the general system, only inside a terminal
Casper opens. PATH injection (rather than an absolute path in settings) keeps
`casper` literally available only in Casper terminals, so nothing pollutes the
rest of the system.

**How to apply:** `ClaudeCodeAdapter.surfaceEnvironment(...)` takes optional
`casperDirectory` + `basePath` and, when given, sets
`PATH = "<casperDirectory>:<basePath>"` (or just `<casperDirectory>` when
basePath is empty). The app supplies the app bundle's executable directory
(`Bundle.main.executableURL`'s parent) and the inherited `PATH`. Trade-off:
running `claude` from a non-Casper terminal — in any project, since the hook is
global — leaves the hook command not found; this is acceptable, as it is outside
Casper's scope. See [[hooks-install-once]], [[project]].
