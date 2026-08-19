# Casper

[![CI](https://github.com/alexandreroman/casper/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandreroman/casper/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Casper is a native macOS app that embeds [libghostty][ghostty] to give every
**Git worktree** its own terminal workspace — built for developers running code
agents. It tracks each agent's state and task progress, reserves network ports
per workspace, and bundles a native browser and diff viewer.

> **Status:** under active development and not yet ready for general use. All the
> core layers — the terminal engine, the Git worktree layer, and the `casper`
> control CLI — and the SwiftUI app (Space-grouped sidebar, linked worktrees,
> tmux-style split panes, browser, and diff viewer) are built and have passed a
> live GUI verification pass; polish is ongoing. Claude Code is the first
> supported agent.

## Features

- **Worktree = workspace** — each workspace maps to a Git worktree; creating one
  opens a plain Ghostty terminal in that worktree (no agent is auto-launched).
  ⌘-click a link in the terminal to open it in your browser.
- **Agent state & progress** — each workspace carries an agent state
  (`working` / `blocked` / `idle` / `done` / `unknown` / `error`) and a
  `completed / total` todo progress bar, surfaced in the sidebar with
  pending-notification dots. State is inferred from terminal output by built-in
  detection (no hooks) and can also be set explicitly via the `casper` CLI
  (see below).
- **Split-pane layout** — tmux-style nested splits (one terminal per pane, no
  tabs); a collapsible right-hand inspector offers a `WKWebView` browser and a
  native diff view per workspace.
- **Per-workspace port reservation** — a contiguous block of 10 ports per
  workspace, injected as `CASPER_PORT` in worktree workspaces only, so the same
  app can run once per worktree without collisions. The repository's main
  working tree gets no `CASPER_PORT` and keeps the project's default ports.
- **Native & lean** — prefers built-in macOS frameworks; only four external
  dependencies (libghostty, swift-argument-parser, libgit2, and HighlightSwift
  for diff syntax highlighting); **arm64-only**.

## Installation

Casper is distributed as a standalone `Casper.app`.

1. Download the latest `Casper.app` archive from the [Releases][releases] page.
2. Unzip it and move `Casper.app` to your `/Applications` folder.
3. Launch it like any other macOS app.

**Requirements:** macOS 15 or later, on Apple Silicon (arm64). On first launch,
Casper wires up its code-agent integration for you — no manual setup.

**Updates:** Casper checks for new releases once a day and offers them through
**Casper ▸ Check for Updates…**; nothing is installed without your say-so. Every
update is verified against a signing key embedded in the app, so a tampered
download is refused.

## Building from source

The rest of this document is for contributors who want to build Casper locally.

### Prerequisites

- **Xcode** (full) — required to build and run the tests; the Command Line Tools
  alone cannot link XCTest. Select it with
  `sudo xcode-select -s /Applications/Xcode.app`.
- **libgit2** and **pkgconf** — `brew install libgit2 pkgconf`. CasperGit links
  libgit2 via pkg-config.
- **vendir** — `brew install vendir`. Carvel's file-vendoring tool, used to sync
  the pinned libghostty reference header (`make vendor`).

The first build downloads the pinned `GhosttyKit.xcframework` (~53 MB) from the
`libghostty-spm` release; subsequent builds reuse the extracted artifact.

### Build & test

```bash
git clone <repo-url> casper
cd casper
make vendor  # sync the pinned libghostty header (once)
make build   # compile
make test    # run the test suite
```

Common tasks are exposed through the `Makefile`:

```bash
make          # debug build (default target)
make help     # list available targets
make dev      # recompile and launch the app under a per-branch dev session
make build    # debug build
make test     # run the full test suite
make all      # build then test
make release  # size-optimized release build (arm64)
make bundle   # assemble a self-contained Casper.app (release binary + dylibs)
make dist     # package Casper.app into a downloadable .zip + .sha256 + dSYM
make vendor   # re-sync the pinned libghostty header via Carvel vendir
make clean    # remove build artifacts
```

`make bundle`/`make dist` also need `brew install dylibbundler` to embed the
libgit2 dylib chain so the bundled `Casper.app` runs on a clean Mac.

`make bundle` compiles with `-Osize`, extracts the debug symbols to a
`Casper.dSYM` bundle **next to** `Casper.app`, and strips the shipped
executable. `make dist` publishes that dSYM as its own
`Casper-<version>-arm64.dSYM.zip` archive, so a crash report from a release can
still be symbolicated without shipping the symbols to every user.

### Debug build code signing (optional)

`make build` assembles a minimal `Casper-dev.app` bundle around the debug
binary and signs it with a local **Apple Development** identity whenever one is
available in your keychain. This keeps the Screen Recording permission that the
`debug-casper` skill relies on (for screenshot capture) across rebuilds, instead
of macOS re-prompting after every recompile. The `.app` wrapper is required: a
bare signed executable never registers with macOS's privacy database (TCC) at
all, so only a real bundle can be granted the permission. Without an identity
everything still works — the bundle stays ad-hoc signed and you get the usual
re-prompt-on-rebuild behavior.

To create a free identity once (no paid Developer Program membership needed):

1. Xcode → Settings → Accounts → **+** → Apple ID → sign in with any Apple ID.
2. Select the resulting team → **Manage Certificates…** → **+** →
   **Apple Development**.
3. `make build` picks it up automatically from then on — no configuration
   required.

If `security find-identity -v -p codesigning` still reports 0 identities after
creating the certificate, the Apple WWDR intermediate certificate is likely
missing (`codesign` fails with "unable to build chain to self-signed root").
Download the current intermediate from
<https://www.apple.com/certificateauthority/> (e.g. `AppleWWDRCAG3.cer`) and
install it with `security add-certificates -k login.keychain-db AppleWWDRCAG3.cer`.

See [`.superpowers/plans/screenshot-capture-permissions.md`](./.superpowers/plans/screenshot-capture-permissions.md)
for the full rationale.

### Continuous integration

Tests run on every push to `main` and every pull request via GitHub Actions, on
both `macos-15` (the deployment target's floor) and `macos-26`
([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) — some AppKit layout
behaviour differs between the two, so a single runner would only ever show it as
a failure on the other machine. Tagging a
`v*` release builds and publishes `Casper.app` as a GitHub Release
([`.github/workflows/release.yml`](./.github/workflows/release.yml)), along with
the Sparkle `appcast.xml` feed the in-app updater reads. The release job signs
the archive with the `SPARKLE_PRIVATE_KEY` repository secret and fails if it is
missing — an unsigned feed would be rejected by every installed copy. See
[`.superpowers/plans/sparkle-auto-update.md`](./.superpowers/plans/sparkle-auto-update.md).

## Architecture

Casper is a Swift Package split into focused modules so that the unstable
libghostty API, the libgit2 layer, and agent specifics each stay isolated.

```mermaid
flowchart TD
    App[Casper app + CLI] --> UI[CasperUI]
    App --> Agents[CasperAgents]
    UI --> Core[CasperCore]
    UI --> Ghostty[CasperGhostty]
    Agents --> Core
    Core --> Git[CasperGit]
    Ghostty --> GK[GhosttyKit / libghostty]
    Git --> LG[libgit2]
```

| Module          | Description                                                                           |
| --------------- | ------------------------------------------------------------------------------------- |
| `CasperCore`    | Models, session store, port allocator, control-channel protocol + socket (pure Swift) |
| `CasperGit`     | In-house wrapper over libgit2 (worktrees, diff, status)                               |
| `CasperGhostty` | Embeds GhosttyKit; owns terminal surfaces and layout                                  |
| `CasperAgents`  | Per-surface environment injection (`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, …) |
| `CasperUI`      | SwiftUI sidebar, chrome, diff, and browser views                                      |
| `CasperCLI`     | Domain subcommands, sharing the single app binary (swift-argument-parser)             |

The app and CLI ship as one binary: an empty argv launches the GUI, while a
recognized subcommand runs the CLI and exits.

### CLI

`casper` is only reachable from inside a Casper-opened terminal, where the app
prepends its own binary directory to `PATH`. The CLI is organized by domain,
targeting the workspace behind the current terminal by default:

```bash
casper status set working                    # set the agent state (working|blocked|idle|done|unknown|error)
casper progress set --total 5 --current 2 --label "run tests"
casper progress clear
casper notify --message "needs review"       # raise the attention flag + notify
casper info set --message "## App ready
- API: <http://localhost:8080>"
casper info set --file docs/endpoints.md     # read the Markdown message from a file
printf '## App ready\n' | casper info set    # or read it from stdin
printf '## App ready\n' | casper info set -  # same, with an explicit '-' marker
casper info clear                            # empty the panel and hide its button
casper terminal new                          # open a terminal (split right)
casper terminal list                         # list the workspace's terminals
casper terminal close <id>                   # close a terminal by id
casper browser open https://example.com      # load a URL in the inspector browser
casper browser close                         # collapse the inspector if the browser is showing
casper diff open Sources/App/Main.swift      # open the diff, scroll to a file
casper diff close                            # collapse the inspector if the diff is showing
casper workspace list                        # enumerate workspaces
casper workspace current                     # print the current workspace + path
casper workspace new feature/x               # create a Git worktree workspace
casper workspace delete                      # destroy a workspace (worktree + branch)
casper run [name]                            # run a named .casper.json command in a split (defaults to 'run')
```

Every workspace-scoped command accepts `--workspace <id-or-name>` to target a
workspace other than the current one. Commands talk to the running app over a
Unix domain socket named by `$CASPER_CONTROL_SOCKET`, injected per terminal
alongside `$CASPER_WORKSPACE_ID` — and, in worktree workspaces only,
`$CASPER_PORT`.

Every command is machine-readable: on success it prints a JSON object (or array)
to stdout describing the affected `workspace` and any resulting state; on error
it prints `{"error":"…"}` to stderr and exits non-zero. `workspace delete` is
destructive (it removes the worktree folder and its branch) and refuses the
primary workspace.

Casper has no agent-hook integration: an agent reports its state by calling these
commands itself (e.g. `casper status set working`), so the surface is explicit
and agent-agnostic.

The info panel keeps only the latest `casper info set` message and never
persists it across app restarts; it's reached by hovering or clicking the
info button next to the workspace's branch/space title. A message is capped
at 256 KB; `--message` and `--file` together are an error; and a bare
`casper info set` at an interactive terminal errors instead of waiting on
stdin (pipe, redirect, or the explicit `-` marker all still work).

Clicking a link in the message opens it in the workspace's own browser panel,
since a published endpoint is almost always local; **Command-clicking** it
opens the same link in the system's default browser instead.

### Per-repository configuration (`.casper.json`)

A repository can drop a `.casper.json` file at its root to tailor how Casper
treats its workspaces. Every key lives under `workspace`:

```json
{
  "workspace": {
    "copyFiles": [".env", ".env.local"],
    "scripts": {
      "setup":    "npm install",
      "teardown": "docker compose down",
      "run":      "npm run dev",
      "test":     "npm test"
    }
  }
}
```

- `copyFiles` — patterns for untracked files seeded from the source worktree
  into a new workspace. It replaces the built-in `.env`/`.env.local` default;
  `[]` copies nothing. An invalid entry fails workspace creation before any Git
  mutation.
- `scripts` — shell commands bound to a workspace, each run in a visible
  terminal split. Two reserved keys are lifecycle hooks, run automatically and
  never invocable by hand:
  - `setup` runs once, when the workspace is created (never on restart). A
    non-zero exit keeps its split open with the output and flags the workspace.
  - `teardown` runs just before the workspace is destroyed (after the merge on
    the close path). Deletion proceeds whatever the outcome, bounded by a 30s
    timeout, so a broken cleanup script never traps you.

  Every other key is a named command, launched on demand from the workspace's
  "Run Script" toolbar button and context menu, or with `casper run <name>`. Its
  split closes automatically when the command succeeds (exit 0); on any non-zero
  exit the split stays open with a live shell so you can read the output and
  re-run.

The file is hand-edited (there is no settings UI) and re-read each time it is
needed.

## License

Casper is licensed under the [Apache License 2.0](./LICENSE).

[ghostty]: https://ghostty.org
[releases]: https://github.com/alexandreroman/casper/releases
