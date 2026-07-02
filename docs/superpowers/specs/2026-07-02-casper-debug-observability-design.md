# Casper — Debug & Observability Channel — Design Specification

**Date:** 2026-07-02
**Status:** Approved design, pending implementation plan
**Author:** Alexandre Roman (with Claude)

## 1. Goal

Enable an automated agent (Claude Code) — and the developer — to drive and
observe the running Casper app end-to-end:

- **See** its behavior (screenshot + the terminal's live text).
- **Read** structured logs.
- **Interact** with the UI (inject input, inspect state).

The feature has three components: structured logging (1), a debug control
channel (2), and a project skill that ties them into a runbook (3).

## 2. Hard Constraints

1. **Debug mode must never ship in a distributed release.** The entire control
   channel is gated at **compile time** by `#if DEBUG`, so it is physically
   absent from `make release` (`-c release`, where `DEBUG` is undefined). No
   runtime flag or environment variable can enable it in a release binary.
2. **Logging follows the same rule for verbose output**, but keeps a diagnostic
   floor: `.error`/`.fault` remain in release builds for field crash diagnosis;
   `.debug`/`.info` are gated by `#if DEBUG`.
3. **Respect the module boundaries** and the existing native-first,
   minimum-dependency policy. No new external dependencies: the channel reuses
   `Network.framework` (already used by the hook socket) and `CoreGraphics`.

## 3. Components

### 3.1 Structured logging (`CasperLog`)

- New `CasperLog` facility in **CasperCore**: a thin wrapper over `os.Logger`
  with subsystem `com.github.alexandreroman.casper` and categories `app`,
  `ghostty`, `hooks`, `debug`.
- Replace the two existing `NSLog` call sites (`GhosttyDemo`,
  `GhosttySurfaceView`) with `CasperLog`.
- Add lifecycle events: runtime init, surface attach/detach, debug command
  received/failed.
- **Gating discipline:** `.error`/`.fault` are always compiled in.
  `.debug`/`.info` (verbose events such as surface attach, debug command
  traces) are wrapped in `#if DEBUG`. The wrapper exposes helpers that make the
  gating a one-liner at each call site rather than repeated `#if` blocks.
- **How the agent reads them:**

  ```bash
  log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' --style compact
  log show   --predicate 'subsystem == "com.github.alexandreroman.casper"' --last 5m
  ```

### 3.2 Debug control channel

A **request/response** Unix-domain-socket channel, modeled on the existing
`HookSocket` pattern but **bidirectional** — hooks are fire-and-forget, whereas
debug commands return a reply. The whole channel is compiled only under
`#if DEBUG`.

#### Module placement

- **Protocol types + client + transport → CasperCore** (pure Swift, reusable by
  the CLI):
  - `DebugCommand` / `DebugResponse` — `Codable` request/response envelopes.
  - `DebugSocketServer` / `DebugSocketClient` — the client writes a request,
    the server replies with one JSON message, then the connection half-closes
    (EOF), mirroring the hook-socket framing.
- **Server wiring → `casper` executable target** — the only target that sees
  both the GUI window (CasperGhostty) and CasperCore. It owns the
  `DebugSocketServer` instance and dispatches commands.
- **Decoupling → a `DebugSurfaceProvider` protocol** (enumerate windows /
  surfaces, resolve the focused surface). `GhosttyDemo` conforms to it today;
  the Plan 5 real app conforms later. This keeps CasperGhostty free of
  command-layer semantics and lets the channel survive the demo → app
  transition.

#### Discovery

- When compiled under `#if DEBUG`, the GUI binds a socket at
  `NSTemporaryDirectory()/casper-debug.sock`, overridable via the
  `CASPER_DEBUG_SOCKET` environment variable.
- The `casper debug` CLI client reads the same env var / default path.
- The environment variable only selects the **path** — it never controls
  whether the channel exists. Existence is 100 % compile-time.

#### CLI surface

- A `DebugCommand` (argument-parser) subcommand registered on `CasperCommand`
  **only under `#if DEBUG`**, so `casper debug` does not exist at all in a
  distributed release.

#### v1 verbs

| Verb | Behavior | Backed by |
| --- | --- | --- |
| `dump-state` | JSON: windows, surfaces, working dir, title, cols/rows, focus | app introspection |
| `read-text [--scrollback]` | terminal viewport text (or full screen) as plain text | `ghostty_surface_read_text` |
| `send-text <str> [--enter]` | inject text into the focused surface, optional trailing newline | `GhosttySurface.sendText` |
| `screenshot <path>` | write a PNG of the app window | `CGWindowListCreateImage` |

`read-text` builds a `ghostty_selection_s` from a `VIEWPORT`-tagged top-left/
bottom-right pair (or `SCREEN` with `--scrollback`), calls
`ghostty_surface_read_text`, copies out the `ghostty_text_s` bytes, then frees
them with `ghostty_surface_free_text`. All surface-touching work runs on the
`@MainActor`.

### 3.3 Project skill `debug-casper`

A skill under `.claude/skills/debug-casper/` documenting the observe-act-verify
loop for the agent:

1. `make build` (debug configuration → channel present).
2. Launch the GUI in the background.
3. Wait for `casper-debug.sock` to appear.
4. Drive: `casper debug dump-state` / `read-text` / `send-text` / `screenshot`,
   and read `log show` output.
5. Teardown (terminate the app, clean up the socket).

The skill states explicitly that `make release` does **not** include this
channel, so the runbook only applies to debug builds.

## 4. Testing

- **CasperCore unit tests** (XCTest, matching the existing hook-socket tests):
  - `DebugCommand` / `DebugResponse` Codable round-trip.
  - `DebugSocketServer` ↔ `DebugSocketClient` request/response round-trip over a
    temporary socket path.
- **Surface-touching verbs** (`read-text`, `screenshot`, `send-text`) are
  verified through the `debug-casper` skill's manual GUI harness, consistent
  with how Plan 4 was verified. They cannot be unit-tested without a live
  libghostty surface.

## 5. Out of Scope (v1)

- Mouse / click injection and coordinate-based UI hit-testing.
- `send-key` for modifier combinations and special keys (arrows, Ctrl-C).
  `send-text --enter` covers the common case; richer key injection is a
  deliberate later extension.
- Multi-window / multi-surface addressing beyond "the focused surface".
- Any remote or non-local socket transport.
