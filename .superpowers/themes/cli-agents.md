# Theme: CLI & Agent Hooks (CasperCLI + CasperAgents)

**Modules:** CasperCLI + CasperAgents · **Status:** ✅ built (see `../status.md`) ·
**Code:** `Sources/CasperCLI/`, `Sources/CasperAgents/`

The single GUI+CLI binary and the Claude Code hook pipeline that drives
per-workspace agent state.

## Design

### Single binary (GUI + CLI)

The bundle executable inspects its argv: empty → **GUI mode**; a recognized
subcommand → **CLI mode** (`casper hooks …`), which runs and exits. Parsing uses
swift-argument-parser; the fork happens before the `ParsableCommand` tree.

### Agent state & progress

```
Claude Code (in a Ghostty surface)
   │  hooks: Stop / Notification / SessionStart / PostToolUse:TodoWrite
   ▼
`casper hooks feed`  (reads hook JSON on stdin; $CASPER_SOCKET, $CASPER_WORKSPACE_ID)
   │  JSON {workspace, event, payload}  →  Unix domain socket
   ▼
AgentStateStore  ──►  Sidebar (badge, progress, notification dot)
                 └─►  UserNotifications  (if unfocused & state ∈ {waiting, done})
```

- Casper **never launches an agent**; the user runs Claude Code manually.
- Hooks are installed **once, globally** in `~/.claude/settings.json` (via
  `casper hooks setup` or at app startup), merged not clobbered — **not per
  worktree**. See [[hooks-install-once]].
- The hook command is the **relative** `casper hooks feed`. `casper` is not on the
  global `PATH`; every surface prepends the binary's directory to `PATH`, so the
  command resolves **only** inside Casper terminals. See [[cli-availability]].
- Per-surface env: `CASPER_SOCKET`, `CASPER_WORKSPACE_ID`, `CASPER_PORT[_0..9]`.
- **`unknown`/`error`** states originate here (heartbeat timeout / broken socket),
  not in the pure reducer (`core.md`).

The socket classes use `@unchecked Sendable` + serial-queue discipline under
Swift 6 — see [[swift6-network-concurrency]].

## Remaining (consumed by CasperUI)

- Wire `HookSocketServer.onMessage` → `AgentStateStore`.
- Pass the app bundle's executable directory into
  `surfaceEnvironment(casperDirectory:basePath:)`; install hooks at app startup.
- Run the heartbeat *timer* (the monitor exists; the periodic tick does not).
