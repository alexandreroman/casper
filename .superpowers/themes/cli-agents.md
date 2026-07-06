# Theme: CLI & Agent Hooks (CasperCLI + CasperAgents)

**Modules:** CasperCLI + CasperAgents · **Status:** ✅ built (see `../status.md`)
· **Code:** `Sources/CasperCLI/`, `Sources/CasperAgents/`

The single GUI+CLI binary, its domain command surface, and the Claude Code hook
pipeline that drives per-workspace agent state.

## Design

### Single binary (GUI + CLI)

The bundle executable inspects its argv: empty → **GUI mode**; a recognized
subcommand (e.g. `casper status …`, `casper terminal new`) → **CLI mode**,
which runs and exits. Parsing uses swift-argument-parser; the fork happens
before the `ParsableCommand` tree.

### Domain CLI (`casper <domain> <verb>`)

The CLI is organized by domain, one noun per area of app state, each with a
handful of verbs:

- `status set <state>` — set the agent state of a workspace.
- `progress set --total --current --label` / `progress clear` — set or clear
  todo progress.
- `notify [--message <str>]` — raise the attention flag; `--message` also
  posts a macOS notification.
- `terminal new` — open a new terminal, split right.
- `browser open <url>` — open a URL in the browser panel.
- `diff show [<target>]` — show the diff view.
- `workspace list` / `workspace current` / `workspace new --branch [--base]`
  — enumerate, identify, and create workspaces.

Every workspace-scoped command shares a `--workspace <id-or-name>` option,
defaulting to `$CASPER_WORKSPACE_ID` (set in every Casper terminal); this is
why plain `casper status set running` works with no flags inside a Casper
terminal but needs `--workspace` from anywhere else.

Each command sends a `ControlCommand` to the running app over a Unix domain
socket named by `$CASPER_CONTROL_SOCKET` (also per-surface env, alongside
`$CASPER_WORKSPACE_ID` and `$CASPER_PORT[_0..9]`); the app replies with a
`ControlResponse`. If `$CASPER_CONTROL_SOCKET` is unset, the CLI exits with a
"Casper is not running" error instead of hanging. `casper debug …` is a
separate, `#if DEBUG`-only channel — never present in a release build. See
[[debug-channel-gating]].

`casper hooks setup` / `casper hooks feed` are **removed from the CLI**
(Task 14) — they are not part of the domain surface above. Installing Claude
Code's hooks is deferred to the app's GUI (follow-up, out of scope here).

### Agent state & progress (app-side hook plumbing — unchanged)

```
Claude Code (in a Ghostty surface)
   │  hooks: Stop / Notification / SessionStart / PostToolUse:TodoWrite
   ▼
HookSocketServer  (reads hook JSON; $CASPER_SOCKET, $CASPER_WORKSPACE_ID)
   │  JSON {workspace, event, payload}  →  Unix domain socket
   ▼
AgentStateStore  ──►  Sidebar (badge, progress, notification dot)
                 └─►  UserNotifications  (if unfocused & state in
                       {waiting, done})
```

- Casper **never launches an agent**; the user runs Claude Code manually.
- The app-side hook socket (`HookSocketServer`, `ClaudeCodeAdapter.install`,
  `AppModel.handleHookMessage`) **still exists** and is unchanged by Task 14 —
  only the CLI's `hooks` command family was removed. Hooks were previously
  installed **once, globally** in `~/.claude/settings.json` via
  `casper hooks setup` or at app startup, merged not clobbered — **not per
  worktree**. See [[hooks-install-once]]. Re-wiring hook *installation* through
  the GUI, and bridging Claude Code hooks to the domain commands above (rather
  than the removed `hooks feed` relay), are both follow-up work.
- Per-surface env: `CASPER_SOCKET`, `CASPER_WORKSPACE_ID`, `CASPER_PORT[_0..9]`,
  `CASPER_CONTROL_SOCKET`.
- **`unknown`/`error`** states originate here (heartbeat timeout / broken
  socket), not in the pure reducer (`core.md`).

The socket classes use `@unchecked Sendable` + serial-queue discipline under
Swift 6 — see [[swift6-network-concurrency]].

## Remaining (consumed by CasperUI)

- Install Claude Code hooks from the GUI (replaces the removed
  `casper hooks setup`); wire `HookSocketServer.onMessage` → `AgentStateStore`.
- Bridge Claude Code hook events to the domain commands (`status`, `progress`,
  `notify`) instead of the removed `hooks feed` relay; then dismantle
  `HookSocket`/`handleHookMessage`.
- Pass the app bundle's executable directory into
  `surfaceEnvironment(casperDirectory:basePath:)`.
- Run the heartbeat *timer* (the monitor exists; the periodic tick does not).
