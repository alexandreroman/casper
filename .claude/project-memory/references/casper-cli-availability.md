---
name: casper-cli-availability
description: "No global `casper` install; the binary is reachable only inside Casper-opened terminals via PATH injection (no ~/.local/bin shim)"
type: feedback
---

# casper-cli-availability

The `casper` CLI is **not** installed globally — the design spec's original
`~/.local/bin/casper` shim (§4) is **dropped**. `casper` only needs to be
reachable inside terminals Casper opens, so Casper **prepends its own binary's
directory to `PATH`** in every terminal surface's environment. The global
`~/.claude/settings.json` keeps the *relative* hook command `casper hooks feed`,
which therefore resolves only within Casper's terminals — nowhere else on the
user's system.

**Why:** The user: "La CLI casper n'a pas besoin d'être disponible en temps
normal, mais seulement à l'intérieur d'un terminal ouvert par Casper." Chosen
mechanism = PATH injection (not an absolute path in settings), so `casper` is
literally available only in Casper terminals and nothing pollutes the user's
system.

**How to apply:** `ClaudeCodeAdapter.surfaceEnvironment(...)` takes optional
`casperDirectory` + `basePath` and, when given, sets
`PATH = "<casperDirectory>:<basePath>"` (or just `<casperDirectory>` if basePath
is empty). Plan 5 passes the app bundle's executable dir
(`Bundle.main.executableURL`'s parent) and the inherited `PATH`. Trade-off: if
the user runs `claude` from a NON-Casper terminal — now in any project, since
the hook is global — the hook command is not found; acceptable, as that is
outside Casper's scope. See
[[hooks-install-once]], [[project]].
