---
name: "Domain CLI and control channel"
description: "casper's domain CLI (status/progress/notify/terminal/browser/diff/workspace) ships in release over CASPER_CONTROL_SOCKET; casper hooks is removed from the CLI"
type: project
---

# Domain CLI and control channel

`casper`'s CLI is organized by domain — `status`, `progress`, `notify`,
`terminal`, `browser`, `diff`, `workspace` — one noun per area of app state,
each with a handful of verbs (e.g. `casper status set running`,
`casper workspace new --branch <name>`). Every workspace-scoped command
accepts `--workspace <id-or-name>`, defaulting to `$CASPER_WORKSPACE_ID`
(always set inside a Casper terminal).

Commands send a `ControlCommand` to the running app over a Unix domain socket
named by `$CASPER_CONTROL_SOCKET` (per-surface env, alongside
`$CASPER_WORKSPACE_ID` and `$CASPER_PORT[_0..9]`), and get back a
`ControlResponse`. Unlike the `casper debug` channel (see
[[debug-channel-gating]], which stays `#if DEBUG`-only), this control channel
**ships in every release build** — it is the CLI's normal transport, not a
debug-only backdoor.

`casper hooks setup` and `casper hooks feed` are **removed from the CLI**
(Task 14 of the CLI-domain redesign). Installing Claude Code's hooks is
deferred to the app's GUI, and bridging Claude Code hook events to the domain
commands above (replacing the removed `hooks feed` relay) is a separate
follow-up plan. The app-side hook socket (`HookSocketServer`,
`ClaudeCodeAdapter.install`, `AppModel.handleHookMessage`) is untouched by the
CLI removal — see [[hooks-install-once]] for how hook installation itself
still works today, pending its move to the GUI.

**Why:** the CLI was redesigned around app-state domains instead of a single
`hooks` command, so every workspace-scoped action (state, progress,
notifications, terminals, browser, diff, workspace lifecycle) has its own
namespaced verb; a stable per-surface control socket lets external tools and
agents drive Casper without depending on the removed hook-relay shape.

**How to apply:** add new workspace actions as a new domain/verb pair,
following the `ControlCommand.Verb` + `ControlServer` dispatch + CLI command
pattern already used by `status`/`progress`/`notify`/`terminal`/`browser`/
`diff`/`workspace`. Do not resurrect a `hooks` CLI subcommand; hook wiring
belongs in the GUI installer and the (future) agent bridge.
