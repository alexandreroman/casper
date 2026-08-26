---
name: debug-casper
description: >-
  Observe and drive the running Casper GUI during development: read structured
  logs, dump UI state, read the terminal's live text, inject input, and
  screenshot. Use when manually verifying a change in the real app, reproducing
  a UI issue, or capturing evidence. Debug builds only.
---

# Debugging the Casper app

This channel exists **only in debug builds** (`#if DEBUG`). `make release` does
not include it. Everything below assumes a debug build. `make build` is more
than `swift build`: it also stages and signs `Casper-dev.app` around the binary
(`Scripts/assemble-bundle.sh debug`, an `install_name_tool -add_rpath`, the
`Packaging/Info-dev.plist` substitution, then `codesign`). That bundle is what
makes screenshots work — a bare binary never registers with TCC.

## 1. Build, seed, launch

Always launch under a dedicated **session** so this harness isolates its debug
socket, control socket, and layout file from the user's real Casper instance —
verification never disturbs a running dogfood instance.

Use a **unique** session name per test run, never a fixed one: several agents
may be verifying different branches at the same time, and a shared name would
collide on the same sockets and layout file. Derive it from the current branch
(for readability) plus the shell PID (for uniqueness); keep it within the 1–32
char, `[A-Za-z0-9._-]` limit:

```bash
make build
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr -c 'A-Za-z0-9' '-' | cut -c1-16)
export CASPER_SESSION="test-${branch:-x}-$$"   # e.g. test-my-feature-51377
```

### Seed a space (for workspace-level tests)

A fresh session has **no spaces** — the app opens on the homepage, and there is
no non-interactive "open folder" (`NSOpenPanel` is modal). So to test anything
that needs a real Space/Workspace (most things beyond a bare terminal),
pre-write the session's layout file **before launching**. It lives at
`~/Library/Application Support/Casper/session-$CASPER_SESSION.json` (see
`SessionIdentity.layoutFileName`). Point it at a real Git repo — `isGitRepo` is
not persisted; it is re-probed from `folderPath` at load, so the folder must
actually be Git-backed:

```bash
REPO=$(mktemp -d); REPO=$(cd "$REPO" && pwd -P)   # canonical path (avoids /tmp symlink)
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
SP=$(uuidgen); WS=$(uuidgen); SURF=$(uuidgen); BROW=$(uuidgen)
mkdir -p "$HOME/Library/Application Support/Casper"
cat > "$HOME/Library/Application Support/Casper/session-$CASPER_SESSION.json" <<JSON
{
  "spaces": [{
    "id": "$SP", "name": "test", "folderPath": "$REPO", "isCollapsed": false,
    "workspaces": [{
      "id": "$WS", "name": "test", "worktreePath": "$REPO", "branch": "main",
      "portBase": 47000, "kind": "primary",
      "layout": { "leaf": { "_0": { "id": "$SURF", "kind": { "terminal": { "cwd": "$REPO" } } } } },
      "inspector": { "collapsed": true, "tab": "diff", "width": 780,
        "browser": { "id": "$BROW", "kind": { "browser": { "url": "about:blank" } } } }
    }]
  }],
  "selectedWorkspaceID": "$WS"
}
JSON
```

A malformed file self-heals to an empty session (the app moves it aside to
`session-*.json.corrupt` and starts fresh), so if the app still shows the
homepage, re-check the JSON against the `Session`/`Space`/`Workspace`/`Surface`
Codable in `Sources/CasperCore/Models.swift`. Terminals opened this way are real
Casper surfaces, so `$CASPER_CONTROL_SOCKET` / `$CASPER_WORKSPACE_ID` are
injected and the `casper` CLI works when driven via `send-text`.

### Launch

```bash
Casper-dev.app/Contents/MacOS/casper --session "$CASPER_SESSION" >"/tmp/casper-$CASPER_SESSION.out" 2>&1 &
until [ -S "/tmp/casper-debug-$CASPER_SESSION.sock" ]; do sleep 0.2; done
```

The GUI binds its debug socket at `/tmp/casper-debug-$CASPER_SESSION.sock`;
exporting `CASPER_SESSION` makes every `casper debug …` below derive that same
path (an explicit `CASPER_DEBUG_SOCKET` still overrides it).

## 2. Observe

Structured logs (subsystem `com.github.alexandreroman.casper`):

Use the absolute path `/usr/bin/log`: in common zsh setups `log` is a
shell builtin that shadows the system tool (a bare `log show ...` yields
`(eval):log: too many arguments` and empty output).

The app's lifecycle and command messages are emitted at `.debug` level
(e.g. `debug server listening`, `debug command: dumpState`), so they do
**not** appear in a default `log show`. Live streaming with `--level
debug` is the reliable way to see them:

```bash
/usr/bin/log stream \
  --predicate 'subsystem == "com.github.alexandreroman.casper"' \
  --level debug --style compact
```

Historical lookups need `--info --debug` to include `.info`/`.debug`
messages; `.error`/`.fault` show without those flags (they are the
always-compiled diagnostic floor):

```bash
/usr/bin/log show \
  --predicate 'subsystem == "com.github.alexandreroman.casper"' \
  --last 5m --info --debug --style compact
```

App state as JSON:

```bash
.build/debug/casper debug dump-state
```

Besides geometry, each surface reports `agentState` — what agent-state detection
concluded, the same value the sidebar status icon renders — plus `oscTitle` and
`progressReport`, two of the three inputs detection drew it from (the third is
the viewport text, which `read-text` below returns). Together they make it
possible to verify a detection change against the live app instead of reading
the sidebar by eye or adding temporary logging. Both OSC fields are absent until
the surface has actually received such a sequence.

The terminal's live text (viewport, or `--scrollback` for the full screen):

```bash
.build/debug/casper debug read-text
.build/debug/casper debug read-text --scrollback
```

A screenshot (then read the PNG to "see" the window):

```bash
.build/debug/casper debug screenshot /tmp/casper.png
```

`screenshot`, `dump-state`, `read-text`, and `memory` are idempotent, so the
CLI retries them automatically on transient local-socket transport blips —
they are reliable. The mutating verbs (`send-text`, `send-keys`, `send-key`,
`send-action`, `mouse-move`, `focus`) are **never** retried, so a replay
cannot double-inject input or move focus twice.

## 3. Drive

Inject text into the focused surface (`--enter` presses Return):

```bash
.build/debug/casper debug send-text 'echo hello' --enter
```

Then re-read to verify:

```bash
.build/debug/casper debug read-text
```

## What the harness can (and cannot) see

The debug bridge — `AppModel`'s `DebugSurfaceProvider` conformance, in
`Sources/CasperUI/DebugSurfaceBridge.swift` — exposes **at most one surface**:
the *first* `GhosttySurfaceView` found in the key window's content
hierarchy — i.e. the selected workspace's focused/first pane. Its reported `id`
is the **selected workspace's UUID in Casper's canonical lowercase form**
(`selectedWorkspaceID.casperID`, i.e. `uuidString.lowercased()` — Foundation's
plain `uuidString` is uppercase and is never what the harness prints), not a
per-pane id and not a numeric index. So `dump-state` returns a `surfaces` array
of **at most one element** — it is empty when no key window, no surface view, or
no selected workspace can be resolved. Consequently the harness **cannot reach**
other panes in a split, or any unselected workspace's surface (including a
background/off-screen one).

Because there is never more than one surface, `--target` is essentially
redundant —
just omit it and verbs act on that surface. If you do pass it, `--target` /
`focus` match the id **exactly** (`surfaces.first(where: { $0.id == target })`,
in `DebugServer.resolve`); there is **no** numeric-index form, so `--target 0` /
`focus 0` never match and fail with `no surface with id 0`. Pass the workspace
UUID from `dump-state` instead:

```bash
WS=$(.build/debug/casper debug dump-state | sed -n 's/.*"id" : "\([^"]*\)".*/\1/p' | head -1)
.build/debug/casper debug read-text --target "$WS"
.build/debug/casper debug focus "$WS"          # changes UI focus (not retried)
```

Without `--target`, the verbs that accept it act on the focused surface
(falling back to the first). `dump-state` accepts no `--target` at all, and
`focus` needs its id as a positional argument. An unknown id fails with
`no surface with id <id>` — there is no silent fallback.

### Switching workspace can't be driven by synthetic keys

Selecting another workspace is a `Cmd+<n>` app shortcut
(`WorkspaceShortcutKeyMonitor`), but synthetic keystrokes via
`osascript … keystroke` are rejected with `error 1002` unless the driving
terminal holds Accessibility permission — so the debug channel cannot switch
workspaces on its own. Verify the *selected* workspace directly, or drive the
switch with CGEvent against the key window (see the `gui-synthetic-input`
project-memory note).

## 4. Teardown

```bash
kill %1 2>/dev/null; rm -f "/tmp/casper-debug-$CASPER_SESSION.sock"
unset CASPER_SESSION
```

## Notes

- The ten verbs, with their own options (every one also takes
  `--socket <path>`, defaulting to `$CASPER_DEBUG_SOCKET`, else the
  `$CASPER_SESSION`-derived path, else `/tmp/casper-debug.sock`):

  | Verb                                   | Notes                                              |
  | -------------------------------------- | -------------------------------------------------- |
  | `dump-state`                           | Prints every exposed surface as JSON. No `--target`. |
  | `memory`                               | Process memory, the live-object census and named collection sizes. No `--target`. |
  | `read-text [--scrollback] [--target]`  | Viewport text, or the full screen with `--scrollback`. |
  | `send-text <text> [--enter] [--target]`| Injects text; `--enter` submits with Return.       |
  | `send-keys <text> [--target]`          | Types the text as real per-character key events.   |
  | `send-key <char> [--mods …] [--target]`| One key event; `--mods` takes `ctrl`, `cmd`, `opt`, `shift`, repeatable (`--mods ctrl shift`). |
  | `send-action <name> [--target]`        | Fires a libghostty keybinding action, e.g. `copy_to_clipboard`. |
  | `mouse-move <x> <y> [--target]`        | Injects a mouse position in libghostty top-left coordinates. |
  | `screenshot <path> [--target]`         | Writes a PNG of the app window.                    |
  | `focus <id>`                           | Gives UI focus to a surface. The id is a **required positional**, not `--target`. |

- `read-text` returns the terminal contents as plain text — prefer it over
  screenshots for asserting terminal output.
- Targeting is not uniform: `dump-state` has no `--target` (it always reports
  every exposed surface), `memory` has none either (it describes the process,
  not a surface), and `focus` demands an explicit positional id. The other
  seven default to the focused surface — falling back to the first — when
  `--target` is omitted.
- Only the selected workspace's focused/first surface is ever exposed — see
  "What the harness can (and cannot) see". To exercise a specific pane or
  workspace, select/arrange it in the UI first.
- This is a DEBUG-only channel. A `make release` (`swift build -c release`)
  binary omits the socket server and the `casper debug` subcommand entirely.
- `--target <id>` addresses a surface without changing focus; `focus <id>`
  changes the UI focus. `focus` is not retried (it mutates UI state). The `<id>`
  is the workspace UUID from `dump-state`, never a numeric index.
