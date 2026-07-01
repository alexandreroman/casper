---
name: hooks-install-once
description: "Claude Code hooks are installed once per worktree via `casper hooks setup`, not on every terminal open; `casper hooks feed` is the relay"
type: feedback
---

Casper's CLI groups hook integration under a plural **`hooks`** command with two
plain subcommands: `casper hooks setup [<worktree>]` (install
`.claude/settings.local.json`, defaults to cwd, idempotent) and
`casper hooks feed` (the relay: reads hook JSON on stdin, sends to the socket).
The generated settings file invokes `casper hooks feed` explicitly, so `feed` is
a normal subcommand (no default-subcommand trick).

Installing the hooks file must happen **once per worktree**, not on every
terminal-surface open. Only the per-surface **environment** (`CASPER_SOCKET`,
`CASPER_WORKSPACE_ID`, `CASPER_PORT…`, via `ClaudeCodeAdapter.surfaceEnvironment`)
is injected per terminal — runtime identity, cheap, correct per-surface.

**Why:** The design spec (§7) originally said the hook plumbing is installed "when
a terminal surface is created." The user corrected this: rewriting the settings
file on every terminal open is redundant. Separate the one-time file install from
the per-terminal env injection.

**How to apply:** Casper (Plan 5) calls `casper hooks setup` (or
`ClaudeCodeAdapter.install`) **once when a workspace/worktree is created**, not in
the surface-creation path. `ClaudeCodeAdapter.install` and `surfaceEnvironment` are
already separate functions; keep that split. A `--agent` option and per-agent
`hooks <agent> install` are deferred — v1 is Claude-only. See [[project]].
