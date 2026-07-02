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

```bash
make build
.build/debug/casper >/tmp/casper.out 2>&1 &
```

The GUI binds a debug socket at `/tmp/casper-debug.sock` (override with
`CASPER_DEBUG_SOCKET`). Wait for it:

```bash
until [ -S /tmp/casper-debug.sock ]; do sleep 0.2; done
```

## 2. Observe

Structured logs (subsystem `com.github.alexandreroman.casper`):

```bash
log show --predicate 'subsystem == "com.github.alexandreroman.casper"' \
  --last 2m --style compact
# or live:
log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' \
  --style compact
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

## 3. Drive

Inject text into the focused surface (`--enter` presses Return):

```bash
.build/debug/casper debug send-text 'echo hello' --enter
```

Then re-read to verify:

```bash
.build/debug/casper debug read-text
```

## 4. Teardown

```bash
kill %1 2>/dev/null; rm -f /tmp/casper-debug.sock
```

## Notes

- The four verbs are `dump-state`, `read-text [--scrollback]`,
  `send-text <text> [--enter]`, and `screenshot <path>`.
- `read-text` returns the terminal contents as plain text — prefer it over
  screenshots for asserting terminal output.
- All verbs target the focused surface (falling back to the first surface).
- This is a DEBUG-only channel. A `make release` (`swift build -c release`)
  binary omits the socket server and the `casper debug` subcommand entirely.
