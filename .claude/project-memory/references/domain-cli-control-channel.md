---
name: "Domain CLI and control channel"
description: "casper control-channel verbs: behavior specifics the CLI theme leaves out, and the checklist for adding a verb"
type: project
---

# Domain CLI and control channel

`.superpowers/themes/cli-agents.md` records the noun-per-domain rule and why
`run` sits at the top level, targeting, transport, the JSON-output and
exit-code contract (entity ids keyed by type name included) and the no-hooks
decision; `README.md` § CLI is the verb inventory, and the per-verb JSON shapes
live in `Sources/CasperCLI/JSONOutput.swift`. This note keeps what none of them
records. The control channel (`casper <domain> <verb>` over
`$CASPER_CONTROL_SOCKET`) **ships in every release build**, unlike the
`#if DEBUG`-only `casper debug` channel ([[debug-channel-gating]]) and the
`#if DEBUG`-only `--session` flag ([[app-sessions]]).

## Behavior specifics

- Every url argument must be **absolute** — scheme **and** host — and is
  validated CLI-side before the app is contacted.
- `browser open` selects the browser tab, as `diff open` selects the diff tab.
  The browser-automation verbs get or create the inspector browser's
  `BrowserCoordinator`, so they work even when the panel is collapsed or was
  never shown (see [[browser-automation-cli]]).
- `diff open [<file>]` opens the diff view and scrolls to `<file>`, a path
  relative to the target workspace's worktree root (or absolute), resolved
  app-side rather than against the shell's directory. It matches a diff file id
  by its exact worktree-relative path. The file must be inside the worktree
  (`WorkspaceFilePath` containment) **and** either exist on disk or be listed
  by a fresh diff — a file deleted from the worktree — else an error. Only a
  path missing from disk pays for that diff read, so the reply waits on it
  (the handler is `async`). A valid but unchanged file opens the diff without
  scrolling.
- `workspace new` takes the new branch name as a **required positional**, never
  an option; `--base` and `--command` are its only verb-specific options.
  `workspace delete` takes no positional at all — it names its target through
  the shared `--workspace` option.
- `workspace delete` is **destructive**: prunes the linked worktree (deleting
  its folder), deletes its branch in the origin repo, and drops it from the UI.
  It **refuses a primary workspace**, and git cleanup runs before the UI removal
  so a git failure leaves the workspace intact/retryable.
- Session persistence does **not** store the transient fields
  (`.superpowers/themes/core.md` § Design → "`SessionStore`") — they reset on
  load. A handler that writes **only** transient fields therefore does not call
  `persist()`: agents drive `status set` / `notify` on a hot path, and a save
  there costs a main-actor session encode plus a disk write of a byte-identical
  file. Only a handler's genuinely-persisted side effect (a Space expanding, an
  inspector tab change) justifies the save.
- `workspace new` runs its libgit2 checkout off the main actor and replies from
  a `Task`, the same asynchronous shape as `workspace delete` and the
  browser-automation verbs — the GUI stays live while a large repo checks out.
- `notify` does not raise the attention bubble when the target is focused
  (selected **and** the app window is key); the bubble clears when a workspace
  becomes focused again.

**Why:** the theme and `JSONOutput.swift` are the design references; these
specifics are the decisions behind individual verbs that a change to one of
them must keep.

**How to apply:** add a new action as a new `ControlCommand.Verb` +
`ControlServer` dispatch case + CLI command + JSON output struct, following the
existing domains. Success emits the resulting resource state including the
affected `workspace`, with every entity id keyed by its type name (the theme's
§ JSON output); every error path must exit non-zero.
