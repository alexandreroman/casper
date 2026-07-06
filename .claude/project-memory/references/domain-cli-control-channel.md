---
name: "Domain CLI and control channel"
description: "casper's domain CLI emits JSON over CASPER_CONTROL_SOCKET; full verb surface, error paths exit non-zero; hooks CLI removed"
type: project
---

# Domain CLI and control channel

`casper`'s CLI is organized by domain — one noun per area of app state, each
with a handful of verbs. Full surface:

- `status set <state>`
- `progress set --total --current --label` / `progress clear`
- `notify [--message <str>]`
- `terminal new [--command <cmd>] [--working-dir <dir>]` / `terminal list` /
  `terminal close <id>`
- `browser open <url>` (the url must be absolute — scheme **and** host)
- `diff open [<file>]`
- `workspace list` / `workspace current` / `workspace new --branch [--base]` /
  `workspace delete`

Every workspace-scoped command accepts `--workspace <id-or-name>`, defaulting to
`$CASPER_WORKSPACE_ID` (set in every Casper terminal). Each command sends a
`ControlCommand` to the running app over a Unix domain socket named by
`$CASPER_CONTROL_SOCKET` (per-surface env, alongside `$CASPER_WORKSPACE_ID` and
`$CASPER_PORT[_0..9]`) and gets back a `ControlResponse`. This control channel
**ships in every release build** — unlike the `#if DEBUG`-only `casper debug`
channel ([[debug-channel-gating]]).

## JSON output (every command)

- **Success** → a JSON object/array on stdout, exit 0, describing the resulting
  resource state and always including the affected `workspace` id. Examples:
  `status set waiting` → `{"status":"waiting","workspace":"<id>"}`;
  `progress set` → `{"progress":{"total":..,"current":..,"label":".."},"workspace":".."}`;
  verbs with no meaningful state (`progress clear`, `notify`, `browser open`,
  `diff open`) → `{"workspace":"<id>"}`. `terminal new`/`terminal list` carry
  `working-dir` (always) and `command` (only when non-default). `workspace
  new`/`list`/`current` carry `path` (the worktree); `branch` is omitted when
  empty (a degenerate, non-Git space). `workspace list` is a bare JSON array.
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
  **terminal-only** (`applyNewBrowser` removed).
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

## Hooks (removed from the CLI)

`casper hooks setup` / `casper hooks feed` are **removed from the CLI**.
Installing Claude Code's hooks is deferred to the app's GUI, and bridging Claude
Code hook events to the domain commands above (replacing the removed `hooks
feed` relay) is a separate follow-up. The app-side hook socket
(`HookSocketServer`, `ClaudeCodeAdapter.install`, `AppModel.handleHookMessage`)
is untouched by the CLI removal — see [[hooks-install-once]].

**Why:** the CLI is an explicit, agent-agnostic, machine-readable surface: every
workspace action has its own namespaced verb, emits JSON, and a stable
per-surface control socket lets external tools and agents drive Casper without
depending on the removed hook-relay shape.

**How to apply:** add a new action as a new `ControlCommand.Verb` + `ControlServer`
dispatch case + CLI command + JSON output struct, following the existing domains.
Success emits the resulting resource state including the affected `workspace`;
every error path must exit non-zero. Do not resurrect a `hooks` CLI subcommand.
