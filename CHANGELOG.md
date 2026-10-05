# Changelog

All notable changes to Casper are documented in this file.

The format is based on [Keep a Changelog][keepachangelog], and this project
adheres to [Semantic Versioning][semver]. Entries describe user-visible changes;
CI, test, and documentation-only work is left out.

## [0.1.2] - 2026-10-05

### Fixed

- The diff view now shows a renamed file as a single renamed entry,
  `old → new`, instead of a deletion and an addition — including a file moved
  without `git mv`.
- The title-bar diff badge stays visible, as `+0 −0`, when the only change is
  a rename, so the diff view is still one click away.
- Ctrl+Return in a terminal now reaches the program running in it — such as
  Claude Code, which uses it to force-send a message — instead of opening the
  pane's context menu.
- A workspace's scripts can no longer be run while its `setup` script is still
  running: the Run button and the Run Script menu items are disabled meanwhile,
  and `casper run` reports an error. Closing or deleting the workspace in the
  meantime still runs its `teardown` script.

## [0.1.1] - 2026-09-25

### Fixed

- The outdated-integration reminder now also covers opencode installs
  registered from Git or a local checkout — the install the integration
  documents — which previously never reported their version.
- In full screen with the sidebar collapsed, the title bar's trailing controls
  (Merge, Run, Editor, inspector selector) now sit against the right edge
  instead of stopping short of it.

## [0.1.0] - 2026-09-23

Initial release.

### Added

- One terminal workspace per Git worktree, backed by an embedded libghostty
  terminal with tmux-style split panes.
- Per-workspace agent state (`working`, `blocked`, `idle`, `done`, `unknown`,
  `error`) and todo progress bar in the sidebar, inferred from terminal output
  or set through the `casper` CLI.
- Integrations with Claude Code, OpenAI Codex CLI, and opencode through the
  integration plugin.
- A collapsible inspector with a `WKWebView` browser panel and a native diff
  view per workspace.
- A contiguous block of 10 ports reserved per worktree workspace, exposed as
  `CASPER_PORT`.
- Per-repository `.casper.json` configuration: `setup` and `teardown` hooks,
  named commands, and untracked files copied into new worktrees.
- The `casper` CLI to drive workspaces, terminals, the browser panel, the diff
  view, the info panel, and notifications.
- **Open in Editor** for Visual Studio Code, IntelliJ IDEA, and Xcode.
- Automatic updates through Sparkle.

[keepachangelog]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html
[0.1.2]: https://github.com/alexandreroman/casper/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/alexandreroman/casper/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexandreroman/casper/releases/tag/v0.1.0
