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
not include it. Everything below assumes a debug build (`make build`, which maps
to `swift build`).

## 1. Build and launch

Always launch under a dedicated **session** (`dev`) so this harness isolates its
debug socket, control socket, and layout file from the user's real Casper
instance — verification never disturbs a running dogfood instance.

```bash
make build
.build/debug/casper --session dev >/tmp/casper.out 2>&1 &
export CASPER_SESSION=dev   # every `casper debug …` below inherits this
```

Under `--session dev` the GUI binds its debug socket at
`/tmp/casper-debug-dev.sock`. Exporting `CASPER_SESSION=dev` makes every
`casper debug …` derive that same path (an explicit `CASPER_DEBUG_SOCKET` still
overrides it). Wait for the socket:

```bash
until [ -S /tmp/casper-debug-dev.sock ]; do sleep 0.2; done
```

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

The terminal's live text (viewport, or `--scrollback` for the full screen):

```bash
.build/debug/casper debug read-text
.build/debug/casper debug read-text --scrollback
```

A screenshot (then read the PNG to "see" the window):

```bash
.build/debug/casper debug screenshot /tmp/casper.png
```

`screenshot`, `dump-state`, and `read-text` are idempotent, so the CLI
retries them automatically on transient local-socket transport blips —
they are reliable. `send-text` is **not** retried, to avoid
double-injecting input.

## 3. Drive

Inject text into the focused surface (`--enter` presses Return):

```bash
.build/debug/casper debug send-text 'echo hello' --enter
```

Then re-read to verify:

```bash
.build/debug/casper debug read-text
```

## Target a specific surface

`dump-state` reports a stable `id` per surface. Address one directly (without
moving the UI focus):

```bash
.build/debug/casper debug read-text --target 0
.build/debug/casper debug send-text 'ls' --enter --target 0
.build/debug/casper debug screenshot /tmp/casper.png --target 0
```

Or change the actual UI focus to a surface:

```bash
.build/debug/casper debug focus 0
```

Without `--target`, verbs act on the focused surface (falling back to the
first). An unknown id fails with `no surface with id <id>` — there is no silent
fallback. The single-window demo exposes one surface, id `0`; Plan 5 adds more.

## 4. Teardown

```bash
kill %1 2>/dev/null; rm -f /tmp/casper-debug-dev.sock
unset CASPER_SESSION
```

## Notes

- The four verbs are `dump-state`, `read-text [--scrollback]`,
  `send-text <text> [--enter]`, and `screenshot <path>`.
- `read-text` returns the terminal contents as plain text — prefer it over
  screenshots for asserting terminal output.
- All verbs target the focused surface (falling back to the first surface).
- This is a DEBUG-only channel. A `make release` (`swift build -c release`)
  binary omits the socket server and the `casper debug` subcommand entirely.
- `--target <id>` addresses a surface without changing focus; `focus <id>`
  changes the UI focus. `focus` is not retried (it mutates UI state).
