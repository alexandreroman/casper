---
name: hooks-install-once
description: "Claude Code hooks are installed once GLOBALLY (user-level ~/.claude/settings.json) via the CLI or at app startup — not per worktree; `casper hooks feed` relays"
type: feedback
---

# hooks-install-once

Casper installs its Claude Code hooks **globally, once**, into the **user-level
`~/.claude/settings.json`** — triggered via the CLI (`casper hooks setup`) or
once at app startup. It is **not** installed per worktree. The hook command
is the *relative* `casper hooks feed`, which resolves only inside Casper-opened
terminals (where Casper injects `casper` onto `PATH`); in any other terminal it
is simply not found — an accepted trade-off (see [[cli-availability]]).

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
terminal — runtime identity, cheap, correct per-surface. Inside Casper's
terminals the env is always present, so the relay has the identity it needs.
Outside them `casper` is not on `PATH`, so the global hook is not found and does
nothing (a benign shell error) — which keeps it contained to Casper even though
it lives in the user's global settings.

**Why:** rewriting a per-worktree settings file for every worktree is redundant
and pollutes each project; a single **global** install, triggered by the CLI or
at app startup, avoids that. The design spec, README, and the Space spec/plan
describe this global model.

**How to apply:** `ClaudeCodeAdapter.install` targets `~/.claude/settings.json`
(the path is injectable for tests) and merges into it. The app-startup path
calls it; it does not iterate worktrees. A `--agent` option and per-agent
`hooks <agent> install` are deferred — v1 is Claude-only.

**Update (Task 14):** `casper hooks setup` and `casper hooks feed` are removed
from the CLI — the global-install model above still holds, but the *trigger*
is now app-startup only, pending a GUI installer (follow-up). See
[[domain-cli-control-channel]] for the CLI that replaced the `hooks` command
family.
