# Changelog

All notable changes to Casper are documented in this file.

The format is based on [Keep a Changelog][keepachangelog], and this project
adheres to [Semantic Versioning][semver]. Entries describe user-visible changes;
CI, test, and documentation-only work is left out.

## [Unreleased]

### Added

- A light theme. Casper now follows the system's Light or Dark appearance,
  switching live — sidebar, title bar, diff view and terminals included. The
  terminal's light palette is GitHub Light, and the terminal background matches
  the app's content background in both appearances. An explicit `background` or
  `foreground` in your Ghostty configuration applies in both appearances; use
  `theme = light:…,dark:…` for per-appearance colours.

### Fixed

- A `theme` set in your own Ghostty configuration now applies to Casper's
  terminals when Casper can load it (an absolute path, or a theme in
  `~/.config/ghostty/themes/`); otherwise Casper keeps its light and dark
  themes.
- A terminal that failed to start while your displays were asleep — such as
  the one in a workspace an agent opens with `casper workspace new --command`
  while you are away — now starts on its own once they wake, instead of
  waiting until you select the workspace.
- A failed workspace creation no longer leaves behind Git state that makes the
  next attempt under the same name fail with "directory exists".
- Creating a workspace under a name Git already has a worktree entry for no
  longer deletes that worktree's folder. The error now says so, and suggests
  `git worktree prune` when that worktree was deleted, instead of showing Git's
  "directory exists".
- "Create Workspace…" now says why a workspace could not be created — for
  example a repository with no commits yet — instead of a generic guess.
- A file Casper cannot read no longer blanks the whole diff view; it is listed
  as unreadable.
- `casper` commands fail at once instead of hanging for several seconds when
  Casper quit uncleanly and left its socket behind.
- A `casper` command that times out, such as a `casper browser` command on a
  page that does not answer, now fails after its timeout instead of retrying
  for up to a minute.
- The opencode integration reminder no longer claims the plugin is missing
  when `opencode.json` uses Windows line endings and contains a comment.
- A mouse's Back and Forward buttons reach terminal programs as buttons 8 and
  9, as in Ghostty, instead of scrolling them. A mouse's other extra buttons
  reach terminal programs too, numbered as in Ghostty.
- Releasing a right-hand modifier key (Shift, Control, Option or Command) while
  the left one is still held now reaches terminal programs as a release, so a
  program tracking key presses no longer sees that modifier stuck down.
- Moving the window to a display with a different scale no longer leaves the
  terminal sized for the previous display until the window is resized.
- `casper workspace new --base ""` falls back to the space's base branch, as
  if `--base` were omitted, instead of creating a workspace that cannot be
  closed.
- `casper diff open <file>` no longer scrolls to a different changed file that
  shares the name of an unchanged one.
- The diff view no longer jumps back to a file requested earlier with
  `casper diff open` when it is reopened, and no longer jumps to a requested
  file that only changes later.
- Files with Windows (CRLF) or classic Mac (CR) line endings, or that start or
  end with a blank line, get syntax colours in the diff view.
- `casper browser reload --wait` waits for the reloaded page to finish loading
  instead of returning before the reload has started.
- `casper browser screenshot` with `--width`, `--height` or `--url` no longer
  fails on a page that redirects itself while loading.

## [0.1.3] - 2026-10-13

### Added

- The buttons in a workspace's title bar now show they are being pressed: the
  button darkens and shrinks slightly until it is released.

### Fixed

- Command-clicking a link in the info panel opens it in the default browser
  again, wherever in the link you click and however long Command was held
  beforehand.

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
[Unreleased]: https://github.com/alexandreroman/casper/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/alexandreroman/casper/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/alexandreroman/casper/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/alexandreroman/casper/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexandreroman/casper/releases/tag/v0.1.0
