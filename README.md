# Casper — a macOS terminal built for coding agents

[![CI](https://github.com/alexandreroman/casper/actions/workflows/ci.yml/badge.svg)](https://github.com/alexandreroman/casper/actions/workflows/ci.yml)
[![License: Apache
2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Casper is a native macOS app that embeds [libghostty][ghostty] to give every
**Git worktree** its own terminal workspace — built for developers running code
agents. It tracks each agent's state and task progress, reserves network ports
per workspace, and bundles a native browser and diff viewer.

## Features

- **Worktree = workspace** — each workspace maps to a Git worktree; creating one
  opens a plain Ghostty terminal in that worktree (no agent is auto-launched).
  ⌘-click a link in the terminal to open it in your default browser.
- **Agent state & progress** — each workspace carries an agent state (`working`
  / `blocked` / `idle` / `done` / `unknown` / `error`) and a todo progress bar
  filled to the completed fraction, surfaced in the sidebar with
  pending-notification dots. Every state but `error` is inferred from terminal
  output by built-in detection (no hooks); all six can also be set explicitly
  via the `casper` CLI (see below).
- **Agent integrations** — works with Claude Code, OpenAI Codex CLI, and
  opencode, and launches none of them. A dedicated integration plugin covers
  all three agents and wires their lifecycle to Casper. See
  [Coding agents](#coding-agents).
- **Split-pane layout** — tmux-style nested splits (one terminal per pane, no
  tabs); a collapsible right-hand inspector offers a `WKWebView` browser and a
  native diff view per workspace.
- **Open in Editor** — a title-bar split button opens the workspace's worktree
  in Visual Studio Code, IntelliJ IDEA, or Xcode; it appears only when one of
  them is installed.
- **Per-workspace port reservation** — a contiguous block of 10 ports per
  workspace, injected as `CASPER_PORT` in worktree workspaces only, so the same
  app can run once per worktree without collisions. The repository's main
  working tree gets no `CASPER_PORT` and keeps the project's default ports.
- **Native & lean** — prefers built-in macOS frameworks, with a handful of
  external dependencies; **arm64-only**.

## In practice

With [casper-skills][casper-skills] installed, your agent already knows this
whole surface — terminals, the browser panel, the diff view, workspaces,
`.casper.json`. So you ask for what you want in plain language, and it drives
Casper itself. The `casper` commands quoted below are what it runs for you;
[CLI](#cli) documents them if you'd rather type them yourself.

### "Start the app, open the home page and take a screenshot"

The agent opens the dev server in its own split (`casper terminal new
--command`), loads the page in the workspace's browser panel
(`casper browser open`), and hands you back a PNG (`casper browser screenshot`)
— all without leaving the terminal you're talking to it in.

From there the same panel is its feedback loop: it can click and type
(`casper browser click` / `type`), wait for an element (`casper browser wait`),
evaluate JavaScript (`casper browser eval`), and read the page's uncaught
errors (`casper browser console`). So "the submit button does nothing, fix it"
becomes something it can actually check before telling you it's done.

### "Take this in a new workspace and work on it there"

Each workspace is a Git worktree, so agents working in parallel never share a
checkout, a branch, or a build directory. The agent creates one on demand
(`casper workspace new feature/login`), Casper does the `git worktree`
bookkeeping and seeds the untracked files listed in
[`.casper.json`](#per-repository-configuration-casperjson), and the new
workspace can start with its own agent already running in it.

The sidebar then shows every agent's state and todo progress side by side, with
a dot on the ones waiting for you; `⌘1`–`⌘9` jumps between them. When the branch
is done, closing the workspace removes the worktree and its branch in one step.

### "Keep the server and the logs running while you work"

Long-running processes don't have to tie up the agent's prompt: it opens each
one in a visible split (`casper terminal new --command "npm run dev"`), leaves
it there, and keeps going. You watch the output in the workspace as it happens,
and the agent closes the splits when it no longer needs them.

### "Run it here too, it won't clash"

Every worktree workspace reserves a contiguous block of 10 ports and exposes the
first as `CASPER_PORT`, so the same server runs in all of them at once with no
port to arbitrate — the agent starts it on `$CASPER_PORT` and points the browser
panel at it.

### "Now tell me where it's listening"

Ports that shift from workspace to workspace are exactly what you don't want to
hunt for in the scrollback, so the agent publishes them once, in the workspace's
info panel (`casper info set`), as Markdown:

```bash
casper info set --message "## Dev server
- App: <http://localhost:$CASPER_PORT>
- API: <http://localhost:$CASPER_PORT/api>
- Health: <http://localhost:$CASPER_PORT/actuator/health>"
```

The panel hangs off the info button next to the workspace's title, so those
addresses stay one hover away however far the terminal has scrolled, and
clicking one opens it in this workspace's own browser panel (⌘-click sends it to
your default browser). It's the workspace's scratchpad for anything you'll want
to come back to — the endpoints it just started, the plan it's about to follow,
what it found while investigating. Only the latest message is kept, and it never
survives an app restart; `casper info clear` empties it.

### "Set this repo up so a new workspace is ready to go"

A repository's `.casper.json` binds shell commands to its workspaces: `setup`
runs once when a workspace is created (install dependencies, start containers),
`teardown` just before it is destroyed, and every other entry is a named command
launched from the toolbar or with `casper run <name>`. The agent writes that
file for you — it knows the schema.

### It tells you when it's stuck

You don't have to watch the window. The
[integration plugin](#the-integration-plugin) ties the agent's own lifecycle to
the sidebar: the badge follows its turn, the progress bar mirrors its todo list
step by step, and an agent that needs a decision, a credential or a login raises
a notification and marks itself blocked instead of ending its turn quietly.

## Installation

Casper is distributed as a standalone `Casper.app`.

1. Download the latest `Casper.app` archive from the [Releases][releases] page.
2. Unzip it and move `Casper.app` to your `/Applications` folder.
3. Launch it like any other macOS app.

**Requirements:** macOS 15 or later, on Apple Silicon (arm64). The `casper` CLI
needs no installation: Casper injects it into the `PATH` of every terminal it
opens, so agents and shells running inside a workspace can call it directly.

**Agent integration (strongly recommended):** install
[casper-skills][casper-skills] for the agent you use. Casper works fine without
it — the sidebar badge still follows the agent through built-in output
detection — but the todo progress bar and the notification dot only move if the
agent calls the `casper` CLI itself. With the plugin its own lifecycle does
that for you, and the badge gets precise instead of inferred. See
[The integration plugin](#the-integration-plugin) for the per-agent installers.

**Updates:** Casper checks for new releases once a day and offers them through
**Casper ▸ Check for Updates…**; nothing is installed without your say-so. Every
update is verified against a signing key embedded in the app, so a tampered
download is refused.

## Coding agents

Casper supports three coding agents — **Claude Code**, **OpenAI Codex CLI**,
and **opencode**. Everything an agent drives *explicitly* is agent-agnostic: the
`casper` CLI verbs behind agent state, progress, notifications and the info
panel behave identically whichever agent calls them, and the working badge
lights up for any agent that emits the standard OSC 9;4 progress sequence.
Casper never launches an agent for you; you start yours in a Casper terminal
yourself.

Agents talk to Casper through the `casper` CLI (see [CLI](#cli)). You can call
those commands by hand, but the usual route is a small **integration plugin**
installed into the agent, which wires the agent's own lifecycle to them so the
sidebar badge, the progress bar and the notification dot work without you
instrumenting anything.

### The integration plugin

That plugin lives in its own repository, [casper-skills][casper-skills], and
covers all three agents from a single source. It wires the agent's own hook or
plugin lifecycle to the `casper` CLI: the sidebar badge follows the turn and
every tool call, the progress bar mirrors the agent's own todo list step by
step, and a blocked agent raises a notification instead of ending its turn
quietly. It also ships a `casper` skill that teaches the agent the rest of the
surface — the info panel, the browser panel, the diff view, extra terminals,
workspaces, and a repository's `.casper.json`. Outside a Casper terminal it
does nothing at all, and it never blocks or fails a turn when Casper isn't
running.

Each agent installs it with its own installer. **Claude Code**, from its TUI:

```text
/plugin marketplace add alexandreroman/casper-skills
/plugin install casper@casper
```

**OpenAI Codex CLI**:

```bash
codex plugin marketplace add alexandreroman/casper-skills
codex plugin add casper@casper
```

**opencode** (drop `-g` to install into the project's config instead):

```bash
opencode plugin github:alexandreroman/casper-skills -g
```

Codex needs one step more: it hashes command hooks it did not install itself, so
this plugin's hooks stay completely inert — installed, current, and doing
nothing — until you review and approve them with `/hooks` in its TUI. An upgrade
that changes a hook sends it back for review, so check `/hooks` after every
update, not only the first install.

## Keyboard shortcuts

| Shortcut  | Action                                              |
| --------- | --------------------------------------------------- |
| `⌘O`      | Add Folder… — open a repository or worktree         |
| `⌘D`      | Split Right                                         |
| `⌘⇧D`     | Split Down                                          |
| `⌘T`      | Split Right (Ghostty's New Tab, remapped — no tabs) |
| `⌘W`      | Close the focused pane                              |
| `⌘1`–`⌘9` | Switch to the sidebar's 1st–9th workspace           |
| `⌘C`      | Copy the terminal selection                         |
| `⌘V`      | Paste into the terminal                             |
| `⌘A`      | Select all in the terminal                          |
| `⌘+`/`⌘-` | Grow / shrink the focused terminal's font           |
| `⌘0`      | Reset the focused terminal's font size              |

Holding ⌘ for a moment reveals the `⌘1`–`⌘9` number hints in the sidebar.

## Building from source

The rest of this document is for contributors who want to build Casper locally.

### Prerequisites

- **Xcode 26 or later** (full) — required to build at all (the project uses
  Swift 6.2 isolated conformances) and to run the tests; the Command Line Tools
  alone cannot link XCTest. Select it with
  `sudo xcode-select -s /Applications/Xcode.app`.
- **libgit2** and **pkgconf** — `brew install libgit2 pkgconf`. CasperGit links
  libgit2 via pkg-config.

The first build downloads the pinned `GhosttyKit.xcframework` (~53 MB) from the
`libghostty-spm` release; subsequent builds reuse the extracted artifact.

### Build & test

```bash
git clone <repo-url> casper
cd casper
make build   # compile (the first run downloads GhosttyKit.xcframework)
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
make icon     # rebuild AppIcon.icns + AppIconDev.icns from the SVGs (needs resvg)
make clean    # remove build artifacts
```

`make bundle`/`make dist` also need `brew install dylibbundler` to embed the
libgit2 dylib chain so the bundled `Casper.app` runs on a clean Mac.

`make vendor` is a **contributor-only** step, not part of building. It needs
`brew install vendir` and re-syncs `Vendor/ghostty/ghostty.h`, a reference-only
copy of the libghostty header, **out of the already-extracted**
`GhosttyKit.xcframework` — so it can only run *after* a successful build, and it
is only worth running when the GhosttyKit pin moves. Nothing in `Sources/`
compiles against the vendored copy; it exists so the exact C API the code
targets stays readable in-tree.

`make release` compiles with `-Osize`; `make bundle` runs it, extracts the debug
symbols to a `Casper.dSYM` bundle **next to** `Casper.app`, and strips the
shipped executable. `make dist` publishes that dSYM as its own
`Casper-<version>-arm64.dSYM.zip` archive, so a crash report from a release can
still be symbolicated without shipping the symbols to every user.

### Debug build code signing (optional)

`make build` assembles a minimal `Casper-dev.app` bundle around the debug binary
and signs it with a local **Apple Development** identity whenever one is
available in your keychain. This keeps the Screen Recording permission that the
`debug-casper` skill relies on (for screenshot capture) across rebuilds, instead
of macOS re-prompting after every recompile. The `.app` wrapper is required: a
bare signed executable never registers with macOS's privacy database (TCC) at
all, so only a real bundle can be granted the permission. Without an identity
everything still works — the bundle stays ad-hoc signed and you get the usual
re-prompt-on-rebuild behavior.

To create a free identity once (no paid Developer Program membership needed):

1. Xcode → Settings → Accounts → **+** → Apple ID → sign in with any Apple ID.
2. Select the resulting team → **Manage Certificates…** → **+** → **Apple
   Development**.
3. `make build` picks it up automatically from then on — no configuration
   required.

If `security find-identity -v -p codesigning` still reports 0 identities after
creating the certificate, the Apple WWDR intermediate certificate is likely
missing (`codesign` fails with "unable to build chain to self-signed root").
Download the current intermediate from
<https://www.apple.com/certificateauthority/> (e.g. `AppleWWDRCAG3.cer`) and
install it with
`security add-certificates -k login.keychain-db AppleWWDRCAG3.cer`.

See the plan
[`tcc-screen-recording-needs-a-bundle.md`](./.claude/project-memory/references/tcc-screen-recording-needs-a-bundle.md)
for the full rationale.

### Continuous integration

Tests run on every push to `main` and every pull request via GitHub Actions, on
both `macos-15` (the deployment target's floor) and `macos-26`
([`.github/workflows/ci.yml`](./.github/workflows/ci.yml)) — TextKit's
cold-layout height estimates differ between the two, so a single runner would
only ever show it as a failure on the other machine. Tagging a `v*` release
builds and publishes `Casper.app` as a GitHub Release
([`.github/workflows/release.yml`](./.github/workflows/release.yml)), along with
the Sparkle `appcast.xml` feed the in-app updater reads. The release job signs
the archive with the `SPARKLE_PRIVATE_KEY` repository secret and fails if it is
missing — an unsigned feed would be rejected by every installed copy. See the
note [`sparkle-eddsa-key.md`](./.claude/project-memory/references/sparkle-eddsa-key.md).

## Architecture

Casper is a Swift Package split into focused modules so that the unstable
libghostty API, the libgit2 layer, and agent specifics each stay isolated.

```mermaid
flowchart TD
    App[casper binary — app + CLI] --> UI[CasperUI]
    App --> CLI[CasperCLI]
    UI --> Core[CasperCore]
    UI --> Git[CasperGit]
    UI --> Ghostty[CasperGhostty]
    UI --> Agents[CasperAgents]
    UI --> HL[HighlightSwift]
    UI --> SP[Sparkle]
    CLI --> Core
    CLI --> Agents
    CLI --> AP[swift-argument-parser]
    Agents --> Core
    Ghostty --> Core
    Ghostty --> GK[GhosttyKit / libghostty]
    Core --> Git
    Git --> LG[libgit2]
    Git --> Shims[Clibgit2 / CSigbusGuard]
```

- **`CasperCore`** — models, session store, worktree manager, port allocator,
  control-channel protocol + socket.
- **`CasperGit`** — in-house wrapper over libgit2 (worktrees, diff, status),
  with the `Clibgit2` module map and the `CSigbusGuard` shim around libgit2's
  diff.
- **`CasperGhostty`** — embeds GhosttyKit; owns terminal surfaces and layout.
- **`CasperAgents`** — per-surface environment injection
  (`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, …).
- **`CasperUI`** — SwiftUI sidebar, chrome, diff, and browser views.
- **`CasperCLI`** — domain subcommands, sharing the single app binary.

The app and CLI ship as one binary, and the routing keys on the *shape* of the
first argument, not on a list of known verbs: empty argv — or a leading `-…`
flag, which is what macOS injects on launch — starts the GUI, while any leading
non-dash word (plus `-h`, `--help` and `--version`) runs the CLI and exits. An
unrecognized word such as `casper bogus` therefore still enters the CLI, which
then reports it as an unknown subcommand.

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
casper terminal new                          # open a terminal (split below)
casper terminal list                         # list the workspace's terminals
casper terminal close <id>                   # close a terminal by id
casper browser open https://example.com      # load a URL in the inspector browser
casper browser close                         # collapse the inspector if the browser is showing
casper diff open Sources/App/Main.swift      # open the diff, scroll to a file
casper diff close                            # collapse the inspector if the diff is showing
casper workspace list                        # enumerate workspaces
casper workspace current                     # print the current workspace + path
casper workspace new feature/x               # create a Git worktree workspace
casper workspace new feature/x --base main --command "claude"
casper workspace delete                      # destroy a workspace (worktree + branch)
casper run [name]                            # run a named .casper.json command in a split (defaults to 'run')
```

`casper workspace new <branch>` takes the branch name as a positional argument
and sanitizes it into a valid Git ref (lowercased, separators collapsed), which
is the form the reply echoes back; `--base <ref>` forks from a ref other than
the space's base branch, and
`--command <cmd>` seeds the workspace's first terminal with a command to run.
`casper terminal new` takes the same `--command <cmd>` to seed the new split,
plus `--working-dir <path>` to start it somewhere other than the workspace's
worktree.

The browser panel doubles as an automation surface, so a coding agent can drive
and inspect the page it just changed:

```bash
casper browser load https://localhost:8080   # navigate without opening the panel
casper browser screenshot --out out.png      # PNG of the page (--width/--height/--url)
casper browser content                       # dump the page's HTML (--selector)
casper browser url                           # print the page's current URL
casper browser eval "document.title"         # evaluate JavaScript in the page
casper browser click "button.submit"         # click the first matching element
casper browser type "input[name=q]" casper   # type into the first matching element
casper browser key Enter                     # dispatch a keydown/keyup to the page
casper browser console                       # captured console output + uncaught errors (--level)
casper browser wait ".ready"                 # block until a selector holds (or --js <expr>)
                                             # --visible/--gone, --timeout <ms> (default 5000)
casper browser reload                        # reload the page
casper browser scroll-down                   # also scroll-up / scroll-top / scroll-bottom
```

Every workspace-scoped command accepts `--workspace <id-or-name>` to target a
workspace other than the current one. The exceptions are the two that aren't
workspace-scoped: `workspace list` enumerates all of them, and
`workspace current` reports the terminal's own workspace from
`$CASPER_WORKSPACE_ID`. Commands talk to the running app over a Unix domain
socket named by `$CASPER_CONTROL_SOCKET`, injected per terminal alongside
`$CASPER_WORKSPACE_ID` — and, in worktree workspaces only, `$CASPER_PORT`.

Every command is machine-readable: on success it prints a JSON object — or, for
the `list` verbs, an array — to stdout describing the workspace and any
resulting state; on error it prints `{"error":"…"}` to stderr and exits
non-zero. Usage errors (an unknown subcommand or flag, a missing option) are the
exception: they keep the argument parser's own plain-text format and exit 64. On
`browser eval`, `content` and `url`, `--raw` prints the bare value instead of
the JSON envelope. Ids are printed in lowercase, and `--workspace` matches an id
in either case. `workspace delete` is destructive (it removes the worktree
folder and its branch) and refuses the primary workspace.

Casper installs and serves no agent hooks of its own: an agent reports its state
by calling these commands itself (e.g. `casper status set working`), so the
surface is explicit and agent-agnostic. A per-agent integration plugin is only a
convenience on top — it wires the agent's lifecycle to exactly these commands.

The info panel keeps only the latest `casper info set` message and never
persists it across app restarts; it's reached by hovering or clicking the info
button next to the workspace's branch/space title. A message is capped at 256
KB; `--message` and `--file` together are an error; and a bare `casper info set`
at an interactive terminal errors instead of waiting on stdin (pipe, redirect,
or the explicit `-` marker all still work).

Clicking an `http(s)` link in the message opens it in the workspace's own
browser panel, since a published endpoint is almost always local;
**Command-clicking** it — or clicking any other scheme — opens it in the
system's default browser instead.

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
[casper-skills]: https://github.com/alexandreroman/casper-skills
