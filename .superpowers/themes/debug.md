# Theme: Debug & Observability

**Status:** ✅ built (see `../status.md`) · **Code:**
`DebugProtocol`/`DebugSocket` (CasperCore), `DebugServer` (CasperGhostty),
`DebugCLICommand` (CasperCLI) · **Skill:** `.claude/skills/debug-casper/`

Developer/agent tooling to drive and observe the running app end-to-end. Merges
two design increments (observability channel, then surface addressing).

## Hard constraint

**Never ships in a release.** The entire channel — protocol, transport, CLI, and
GUI wiring — is gated at **compile time** by `#if DEBUG`, physically absent from
`make release` (`-c release`, `DEBUG` undefined). No runtime flag enables it;
`CASPER_DEBUG_SOCKET` only selects the socket *path* (else `CASPER_SESSION`
derives it, else the default). Logging keeps a floor: `.error`/`.fault` always
compiled in, `.debug`/`.info` gated. See [[debug-channel-gating]].

## Design

- **`CasperLog`** — a thin `os.Logger` wrapper (subsystem
  `com.github.alexandreroman.casper`, three categories: `app`, `ghostty`,
  `debug`).
- **Control channel** — a bidirectional request/response Unix-domain-socket
  channel (protocol + client in CasperCore; the server is
  `CasperGhostty/DebugServer.swift`, started by CasperUI's `AppDelegate` against
  a `DebugSurfaceProvider` — `AppModel`'s conformance lives in
  `CasperUI/DebugSurfaceBridge.swift`). Default path `/tmp/casper-debug.sock`;
  under `--session <name>` (itself a `#if DEBUG`-only flag) it is
  `/tmp/casper-debug-<name>.sock`, and an external driver targets a session by
  exporting `CASPER_SESSION=<name>` (the CLI derives the same path). See
  [[app-sessions]].
- **Verbs** — nine, in three groups:
  - *Observe* — `dump-state` (windows/surfaces/cwd/title/cols/rows/focus),
    `read-text [--scrollback]`, `screenshot <path>`.
  - *Inject* — `send-text <str> [--enter]` (writes the text straight into the
    surface), `send-keys <str>` (the same text as real per-character press +
    release key events), `send-key <key> [--mods …]` (one key with modifiers as
    a real key event, so modifier and special keys are reachable),
    `send-action <name>` (trigger a libghostty keybinding action such as
    `copy_to_clipboard`), and `mouse-move --x --y` (a mouse position in
    libghostty top-left coordinates).
  - *Address* — `focus <id>`.
- **Surface addressing** — each surface has a stable string `id`; `dump-state`
  reports it. `focus <id>` moves UI focus; `--target <id>` acts on a specific
  surface **without** moving focus, and an unmatched target fails cleanly (no
  silent fallback). Seven of the nine verbs take `--target`: `focus` addresses
  by positional id instead, and `dump-state` takes none at all — it enumerates
  every surface, so there is nothing to target.
- **`debug-casper` skill** — the observe-act-verify runbook (build debug,
  launch, wait for the socket, drive, teardown).

## As-built notes (refine the design; code is the source of truth)

- The CasperCore transport/protocol are themselves `#if DEBUG` (verified with
  `nm`/`strings` on the release binary) — not merely their callers.
- Transport uses symmetric **4-byte big-endian length-prefixed framing in both
  directions** (a plain half-close intermittently failed with `ENETDOWN`); an 8
  MB length guard bounds each read.
- **Idempotent-verb retry:** `dump-state`/`read-text`/`screenshot` are retriable
  (up to 4 attempts); every injecting verb and `focus` are **not** (they
  mutate).
- Logging emits `debug server listening`, `debug command: <verb>`,
  `debug command failed: …`; read via the absolute `/usr/bin/log` (a zsh builtin
  shadows `log`).

## Out of scope

Mouse *button* injection (only `mouse-move` positions the pointer; clicks go
through `CGEvent` — see [[gui-synthetic-input]]), non-terminal component
addressing, and any non-local transport.
