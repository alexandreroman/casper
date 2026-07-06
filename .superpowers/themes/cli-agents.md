# Theme: CLI & Agent Environment (CasperCLI + CasperAgents)

**Modules:** CasperCLI + CasperAgents · **Status:** ✅ built (see `../status.md`)
· **Code:** `Sources/CasperCLI/`, `Sources/CasperAgents/`

The single GUI+CLI binary, its domain command surface, and the per-surface
environment that lets an agent in a terminal report its state through the CLI.

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
  posts a macOS notification (suppressed when the target is already focused).
- `terminal new [--command <cmd>] [--working-dir <dir>]` — open a terminal,
  split right (cwd defaults to the worktree); `terminal list` — list the
  workspace's terminals; `terminal close <id>` — close a terminal by id.
- `browser open <url>` — load an **absolute** URL (scheme + host) into the
  workspace's single **inspector** browser surface and select the browser tab
  (there are no browser layout panels; layout panels are terminal-only).
- `diff open [<file>]` — open the diff view and scroll to `<file>` (which must
  exist on disk and be inside the worktree, else an error).
- `workspace list` / `workspace current` / `workspace new --branch [--base]` /
  `workspace delete` — enumerate, identify, create, and destroy workspaces.
  `workspace delete` is **destructive** (prunes the worktree folder, deletes the
  branch, drops it from the UI) and **refuses a primary workspace**.

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

### JSON output

Every command is machine-readable. On **success** it prints a JSON object (or
array) to stdout and exits 0, describing the resulting resource state and always
including the affected `workspace` id — e.g. `status set waiting` →
`{"status":"waiting","workspace":"<id>"}`; verbs with no meaningful state
(`progress clear`, `notify`, `browser open`, `diff open`) → `{"workspace":"<id>"}`.
`terminal new`/`list` carry `working-dir` (always) and `command` (when
non-default); `workspace new`/`list`/`current` carry the worktree `path`
(`branch` omitted for a degenerate, non-Git space). On **error** it prints
`{"error":"<msg>"}` to stderr and exits **non-zero** — a command in error never
returns 0; validate CLI-side in `makeCommand()` where possible. ArgumentParser's
own output (`--help`, missing option, unknown flag) stays native.

### Agent state & progress

Casper has **no agent-hook mechanism** — no hook installation, no hook socket,
no `hooks` CLI. A workspace's agent state (`agentState`, todo progress, the
attention flag) is set **only** by the explicit domain verbs above: an agent (or
any tool) running in a Casper terminal calls `casper status set …`,
`casper progress set …`, and `casper notify …` itself. Casper **never launches an
agent**; the user runs their agent manually.

The only agent-facing runtime coupling is the per-surface environment
`ClaudeCodeAdapter.surfaceEnvironment` injects into every Casper terminal:
`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, `CASPER_PORT[_0..9]`, and — when
the app runs under `--session <name>` — `CASPER_SESSION`. A CLI command reads
`CASPER_WORKSPACE_ID` for its default target and `CASPER_CONTROL_SOCKET` to reach
the app; state changes flow straight into the sidebar (badge, progress,
notification dot) and, for `notify`, `UserNotifications`.

When the app is launched with `--session <name>`, its control socket is the
session-scoped `casper-control-<name>.sock` and that path is the value injected
as `CASPER_CONTROL_SOCKET`, so the domain CLI keeps working unchanged inside a
named session's terminals (it never reads `CASPER_SESSION` — the injected socket
path already points at the right instance). See [[app-sessions]].

The control socket class uses `@unchecked Sendable` + serial-queue discipline
under Swift 6 — see [[swift6-network-concurrency]].
