---
name: "Domain CLI and control channel"
description: "casper's domain CLI emits JSON over CASPER_CONTROL_SOCKET; full verb surface, error paths exit non-zero; no hook mechanism"
type: project
---

# Domain CLI and control channel

`casper`'s CLI is organized by domain — one noun per area of app state, each
with a handful of verbs. Full surface:

- `status set <state>`
- `progress set --total --current --label` / `progress clear`
- `notify [--message <str>]`
- `info set [--message <str> | --file <path> | -]` / `info clear`
- `terminal new [--command <cmd>] [--working-dir <dir>]` / `terminal list` /
  `terminal close <id>`
- `browser open <url>` (the url must be absolute — scheme **and** host) /
  `browser load <url>` (same, but a **background** load — does not open/select
  the inspector) / `browser close`
- `browser screenshot [--out <path>]` / `browser eval <js> [--raw]` /
  `browser content [--selector <css>] [--raw]` / `browser url [--raw]` /
  `browser click <selector>` /
  `browser type <selector> <text>` / `browser key <key> [--selector <css>]` /
  `browser scroll-up` / `browser scroll-down` /
  `browser scroll-top` / `browser scroll-bottom`
  — browser automation over the workspace's inspector `WKWebView`
  (see [[browser-automation-cli]])
- `browser console [--level <lvl>] [--clear]` / `browser wait
  <selector>|--js <expr> [--visible|--gone] [--timeout <ms>]` /
  `browser reload [--wait]` — web-app debugging: page console/error capture,
  deterministic waits, reload (see [[browser-automation-cli]])
- `diff open [<file>]` / `diff close`
- `workspace list` / `workspace current` / `workspace new <branch> [--base]
  [--command]` / `workspace delete` (the branch is a required positional)
- `run [<name>]` — run a named `.casper.json` command in a visible split
  (defaults to the command named `run`); a workspace-targeted verb that sits at
  the top level rather than under a noun

Every workspace-scoped command accepts `--workspace <id-or-name>`, defaulting to
`$CASPER_WORKSPACE_ID` (set in every Casper terminal). `workspace current` is the
one exception: it answers "which workspace is *this* terminal", so it reads
`$CASPER_WORKSPACE_ID` only and takes no target option. Each command sends a
`ControlCommand` to the running app over a Unix domain socket named by
`$CASPER_CONTROL_SOCKET` (per-surface env, alongside `$CASPER_WORKSPACE_ID`,
`$CASPER_PORT` in `linked` workspaces only, and — under `--session <name>`, a
DEBUG-build-only flag — `$CASPER_SESSION`) and gets back a `ControlResponse`.
This control channel **ships in every release build** — unlike the
`#if DEBUG`-only `casper debug` channel ([[debug-channel-gating]]) and the
`#if DEBUG`-only `--session` flag itself. The socket path is **per-session**:
default `casper-control.sock`, or `casper-control-<name>.sock` when a debug
build is launched with `--session <name>` (see [[app-sessions]]); the domain CLI
keys on the injected `$CASPER_CONTROL_SOCKET` path, not `$CASPER_SESSION`.

## JSON output (every command)

- **Success** → a JSON object/array on stdout, exit 0, describing the resulting
  resource state and always including the affected `workspace` id. Examples:
  `status set blocked` → `{"status":"blocked","workspace":"<id>"}`;
  `progress set` → `{"progress":{"total":..,"current":..,"label":".."},"workspace":".."}`;
  verbs with no meaningful state (`progress clear`, `notify`, `browser open`,
  `diff open`) → `{"workspace":"<id>"}`. **Every entity id is keyed by its type
  name — never a bare `id`.** `terminal new` carries `terminal`, `working-dir`
  (always), and `command` (only when specified); `terminal list` elements are
  `{"terminal","working-dir"}` (no `command` — a launch command is a one-shot
  instruction, not durable state). `workspace new`/`list`/`current` elements are
  keyed `workspace` and carry `path` (the worktree) plus `name`; `branch` is
  omitted when empty (a degenerate, non-Git space). `workspace current` returns
  the full descriptor when the id resolves, else the bare `{"workspace"}`.
  `workspace list` is a bare JSON array.
- **Error** → `{"error":"<msg>"}` on stderr with a **non-zero** exit code. Every
  error path (validation, unknown workspace/terminal, invalid url, missing/outside
  file, deleting a primary, …) must exit non-zero — a command in error never
  returns 0. Validate CLI-side in `makeCommand()` when possible so it exits
  before contacting the app.
- ArgumentParser's own output (`--help`, missing required option, unknown flag)
  stays native (not JSON, exit 64).

## Behavior specifics

- `browser open` loads the URL into the workspace's **single inspector browser
  surface** and selects the browser tab (mirroring how `diff open` selects the
  diff tab) — there are no browser layout panels; layout panels are
  **terminal-only**. The browser-automation verbs (`screenshot`/`eval`/
  `content`/`url`/`click`/`type`/`key`) act on that same inspector browser surface,
  getting-or-creating its `BrowserCoordinator` so they work even when the panel
  is collapsed or was never shown (see [[browser-automation-cli]]).
- `diff open [<file>]` opens the diff view and scrolls to `<file>` (resolved
  against diff file ids by exact → path-suffix → basename). The file must exist
  on disk **and** be inside the worktree, else an error (`WorkspaceFilePath`
  containment + existence check). A valid but unchanged file opens the diff
  without scrolling.
- `workspace delete` is **destructive**: prunes the linked worktree (deleting its
  folder), deletes its branch in the origin repo, and drops it from the UI. It
  **refuses a primary workspace**, and git cleanup runs before the UI removal so
  a git failure leaves the workspace intact/retryable.
- Session persistence does **not** store the transient agent state
  (`agentState`, `todos`, `pendingNotification`) — they reset to defaults on load.
- `notify` does not raise the attention bubble when the target is focused
  (selected **and** the app window is key); the bubble clears when a workspace
  becomes focused again.

## No hooks

Casper has no agent-hook mechanism at all — no hook installation, no hook
socket, no `hooks` CLI. A workspace's agent state (status / progress /
notification) is set **only** by the explicit CLI verbs above; an agent (or any
tool) calls `casper status set …` / `progress set …` / `notify …` itself. The
only agent-facing runtime coupling is the per-surface environment
(`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, `CASPER_PORT` in `linked`
workspaces only, and `CASPER_SESSION` under a named session) that
`ClaudeCodeAdapter.surfaceEnvironment` injects into every Casper terminal.

**Why:** an explicit, agent-agnostic, machine-readable surface — every workspace
action has its own namespaced verb, emits JSON, and the stable per-surface
control socket lets external tools and agents drive Casper directly, with no
dependency on a specific agent's hook shape.

**How to apply:** add a new action as a new `ControlCommand.Verb` + `ControlServer`
dispatch case + CLI command + JSON output struct, following the existing domains.
Success emits the resulting resource state including the affected `workspace`;
every error path must exit non-zero.
