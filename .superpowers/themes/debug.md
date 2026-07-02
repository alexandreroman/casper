# Theme: Debug & Observability

**Status:** ✅ built (see `../status.md`) · **Code:** `DebugProtocol`/`DebugSocket`
(CasperCore), `DebugServer` (CasperGhostty), `DebugCLICommand` (CasperCLI) ·
**Skill:** `.claude/skills/debug-casper/`

Developer/agent tooling to drive and observe the running app end-to-end. Merges
two design increments (observability channel, then surface addressing).

## Hard constraint

**Never ships in a release.** The entire channel — protocol, transport, CLI, and
GUI wiring — is gated at **compile time** by `#if DEBUG`, physically absent from
`make release` (`-c release`, `DEBUG` undefined). No runtime flag enables it;
`CASPER_DEBUG_SOCKET` only selects the socket *path*. Logging keeps a floor:
`.error`/`.fault` always compiled in, `.debug`/`.info` gated. See
[[debug-channel-gating]].

## Design

- **`CasperLog`** — a thin `os.Logger` wrapper (subsystem
  `com.github.alexandreroman.casper`, categories `app`/`ghostty`/`hooks`/`debug`).
- **Control channel** — a bidirectional request/response Unix-domain-socket
  channel (protocol + client in CasperCore; server wired in the `casper` target
  via a `DebugSurfaceProvider`). Discovered at
  `NSTemporaryDirectory()/casper-debug.sock`.
- **Verbs** — `dump-state` (windows/surfaces/cwd/title/cols/rows/focus),
  `read-text [--scrollback]`, `send-text <str> [--enter]`, `screenshot <path>`.
- **Surface addressing** — each surface has a stable string `id`; `dump-state`
  reports it. `focus <id>` moves UI focus; `--target <id>` on
  `send-text`/`read-text`/`screenshot` acts on a specific surface **without**
  moving focus. An unmatched target fails cleanly (no silent fallback).
- **`debug-casper` skill** — the observe-act-verify runbook (build debug, launch,
  wait for the socket, drive, teardown).

## As-built notes (refine the design; code is the source of truth)

- The CasperCore transport/protocol are themselves `#if DEBUG` (verified with
  `nm`/`strings` on the release binary) — not merely their callers.
- Transport uses symmetric **4-byte big-endian length-prefixed framing in both
  directions** (a plain half-close intermittently failed with `ENETDOWN`); an
  8 MB length guard bounds each read.
- **Idempotent-verb retry:** `dump-state`/`read-text`/`screenshot` are retriable
  (up to 4 attempts); `send-text` and `focus` are **not** (they mutate).
- Logging emits `debug server listening`, `debug command: <verb>`,
  `debug command failed: …`; read via the absolute `/usr/bin/log` (a zsh builtin
  shadows `log`).

## Out of scope

Mouse/click injection, `send-key` for modifier/special keys, non-terminal
component addressing, and any non-local transport.
