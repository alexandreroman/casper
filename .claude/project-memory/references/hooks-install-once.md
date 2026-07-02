---
name: hooks-install-once
description: "Claude Code hooks are installed once GLOBALLY (user-level ~/.claude/settings.json) via the CLI or at app startup — not per worktree; `casper hooks feed` relays"
type: feedback
---

# hooks-install-once

Casper installs its Claude Code hooks **globally, once**, into the **user-level
`~/.claude/settings.json`** — triggered either via the CLI (`casper hooks setup`)
or once at app startup. It is **not** installed per worktree. User-level hooks
apply to every project Claude Code runs, and `casper hooks feed` no-ops when the
Casper environment variables are absent (see below), so a single global hook is
safe in every terminal — Casper-opened or not.

The CLI groups hook integration under a plural **`hooks`** command:
`casper hooks setup` (merge Casper's hooks into `~/.claude/settings.json`,
idempotent) and `casper hooks feed` (the relay: reads hook JSON on stdin, sends
to the socket). The generated settings invoke `casper hooks feed` explicitly, so
`feed` is a normal subcommand (no default-subcommand trick).

Installing must **merge, never clobber**: `~/.claude/settings.json` holds the
user's own global Claude Code config, so `install` preserves every other
top-level key and non-Casper hook event, dedups Casper's four events by command
(idempotent), and refuses a malformed existing file rather than overwriting it.

Only the per-surface **environment** (`CASPER_SOCKET`, `CASPER_WORKSPACE_ID`,
`CASPER_PORT…`, via `ClaudeCodeAdapter.surfaceEnvironment`) is injected per
terminal — runtime identity, cheap, correct per-surface. `casper hooks feed`
reads `CASPER_WORKSPACE_ID`/`CASPER_SOCKET`; when they are absent (a non-Casper
terminal) it exits 0 without sending, which is why the single global hook is
harmless everywhere.

**Why:** rewriting a per-worktree settings file for every worktree is redundant
and pollutes each project. The user chose a single **global** install, triggered
by the CLI or at app startup. This supersedes the earlier "once per worktree at
creation" guidance (which itself had corrected the original per-terminal spec).
Design spec §7/§10 still describe the superseded per-worktree / per-relaunch
model and must be updated to match.

**How to apply:** `ClaudeCodeAdapter.install` targets `~/.claude/settings.json`
(the path is injectable for tests) and merges into it. `casper hooks setup` and
the Plan 5 app-startup path both call it; neither iterates worktrees. A
`--agent` option and per-agent `hooks <agent> install` are deferred — v1 is
Claude-only. See [[project]].
