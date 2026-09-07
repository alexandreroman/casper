# Theme: Debug & Observability

**Status:** ✅ built (see `../status.md`) · **Code:**
`DebugProtocol`/`DebugSocket` (CasperCore), `DebugServer` (CasperGhostty),
`DebugCLICommand` (CasperCLI) · **Skill:** `.claude/skills/debug-casper/`

Developer/agent tooling to drive and observe the running app end-to-end. Merges
two design increments (observability channel, then surface addressing).

## Hard constraint

**Never ships in a release.** Every file the channel owns is gated at **compile
time** by `#if DEBUG`, physically absent from `make release` (`-c release`,
`DEBUG` undefined): `DebugProtocol`, `DebugSocket`, `LiveObjectCensus` and
`ProcessMemory` (CasperCore), `DebugServer` (CasperGhostty),
`DebugSurfaceBridge` (CasperUI) and `DebugCLICommand` (CasperCLI). The generic
transport engine in `SocketTransport.swift` is the one piece that compiles
unconditionally — it carries no `#if DEBUG` at all — because the
always-shipping control channel (`ControlSocket.swift`) is built on the same
`SocketServerEngine`/`SocketClientEngine`. No runtime flag enables the channel;
`CASPER_DEBUG_SOCKET` only selects the socket *path*, and only on the **dial**
side (else `CASPER_SESSION` derives it, else the default) — a listener always
binds the session-derived path (`DebugSocketPath.listenPath(for:)`), ignoring
the env override outright, see [[socket-listen-vs-dial-path]]. Logging keeps a
floor: `.error`/`.fault` always compiled in, `.debug`/`.info` gated. See
[[debug-channel-gating]].

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
- **Verbs** — ten, in three groups. All ten also take `--socket <path>`, which
  overrides the resolution above, so it is not repeated per verb below:
  - *Observe* — `dump-state` (per surface: id, title, cwd, cols/rows, focus,
    the raw geometry readback and the agent-detection fields),
    `read-text [--scrollback]`, `screenshot <path>`, and `memory` (process
    footprint, the live-object census, and the app's collection sizes).
  - *Inject* — `send-text <str> [--enter]` (writes the text straight into the
    surface), `send-keys <str>` (the same text as real per-character press +
    release key events), `send-key <key> [--mods …]` (one key with modifiers as
    a real key event; the character-to-keycode table covers letters, digits and
    space only, and any other character resolves to nothing and is skipped),
    `send-action <name>` (trigger a libghostty keybinding action such as
    `copy_to_clipboard`), and `mouse-move <x> <y>` (a mouse position in
    libghostty top-left coordinates, as two positional arguments).
  - *Address* — `focus <id>`.
- **Surface addressing** — each surface has a stable string `id`; `dump-state`
  reports it. `focus <id>` moves UI focus; `--target <id>` acts on a specific
  surface **without** moving focus, and an unmatched target fails cleanly (no
  silent fallback). Seven of the ten verbs take `--target`: `focus` addresses
  by positional id instead, and `dump-state` and `memory` take none at all —
  `dump-state` returns the whole set and `memory` describes the process, so
  neither has anything to target. **As built, that set holds at most one
  surface:** `DebugSurfaceBridge` reports only the selected workspace's live
  terminal, located in the key window's view hierarchy, and keys it by the
  *workspace* id. `dump-state` therefore returns zero or one entry, and both
  `--target` and `focus` can only ever resolve to that same surface — the
  addressing machinery is in place, with nothing else to choose from yet.
- **`debug-casper` skill** — the observe-act-verify runbook (build debug,
  launch, wait for the socket, drive, teardown).

## As-built notes (refine the design; code is the source of truth)

- The debug protocol and socket types in CasperCore are themselves `#if DEBUG`,
  not merely their callers: `nm`/`strings` on the release binary find no
  `DebugCommand`/`DebugResponse`/`DebugServer` symbol at all. That check says
  nothing about the shared transport engine, which does ship — the control
  channel needs it.
- Transport uses symmetric **4-byte big-endian length-prefixed framing in both
  directions** (a plain half-close intermittently failed with `ENETDOWN`); an 8
  MB length guard bounds each read.
- **Idempotent-verb retry:** `dump-state`/`read-text`/`screenshot`/`memory` are
  retriable (up to 4 attempts); every injecting verb and `focus` are **not**
  (they mutate).
- Logging emits `debug server listening`, `debug command: <verb>` and
  `debug command failed: <verb> — <reason>`, where `<verb>` is the wire
  `DebugCommand.Verb` rawValue — camelCase (`dumpState`), not the CLI's
  kebab-case subcommand name; read via the absolute `/usr/bin/log` (a zsh
  builtin shadows `log`).

## Out of scope

Mouse *button* injection (only `mouse-move` positions the pointer; clicks go
through `CGEvent` — see [[gui-synthetic-input]]), non-terminal component
addressing, and any non-local transport.
