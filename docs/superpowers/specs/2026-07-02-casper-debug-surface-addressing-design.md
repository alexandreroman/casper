# Casper — Debug Surface Addressing & Focus — Design Specification

**Date:** 2026-07-02
**Status:** Approved design, pending implementation plan
**Author:** Alexandre Roman (with Claude)

## 1. Goal

Extend the `#if DEBUG` debug/observability channel so an agent/developer can
**address a specific surface** and **change the UI focus** deliberately, instead
of always acting on "the focused surface". This lays the addressing scaffolding
now — stable ids, a `focus` verb, and a `--target` option — so the protocol does
not need to change when Plan 5 introduces multiple surfaces (splits, tabs,
per-worktree windows).

Builds on the channel defined in
`2026-07-02-casper-debug-observability-design.md`.

## 2. Scope

- **In scope:** terminal surfaces only, addressed by a stable id.
- **Out of scope (deferred to Plan 5 / later):** non-terminal components
  (sidebar rows, browser, diff view), multi-window addressing beyond the surface
  id, and `send-key` for special keys.

Everything added here is `#if DEBUG` only and physically absent from a release
build, consistent with the `debug-channel-gating` constraint.

## 3. Behavior

### 3.1 Surface id

- Each surface carries a **stable string id assigned by the provider**. The
  single-window demo exposes `"0"`; Plan 5 will map it to the real surface/pane
  identity. Ids are not required to be contiguous integers — they are opaque
  strings the provider owns.
- `dump-state` gains an `id` field per surface:

  ```json
  {
    "id": "0",
    "title": "alex@host:~/Projects/personal/casper",
    "workingDirectory": "/Users/alex/Projects/personal/casper",
    "columns": 103,
    "rows": 29,
    "focused": true
  }
  ```

- **Target resolution:** exact match on `id`. No match →
  `.failure("no surface with id <id>")`.

### 3.2 `focus` verb

- `casper debug focus <id>` changes the actual UI focus to that surface:
  `window.makeFirstResponder(view)`, which triggers `becomeFirstResponder` →
  `GhosttySurface.setFocus(true)`.
- Returns `.success()`. A subsequent `dump-state` reflects `focused: true` on the
  target (and `false` on the previously focused surface).
- Unknown id → `.failure("no surface with id <id>")`.

### 3.3 `--target <id>` option (address without changing focus)

- Added to `send-text`, `read-text`, `screenshot`.
- **Without** `--target`: unchanged behavior — the focused surface, falling back
  to the first.
- **With** `--target <id>`: acts on exactly that surface and does **not** change
  the UI focus. Deterministic and side-effect-free — the visible focus never
  moves as a result of addressing a surface.

## 4. Changes by module (all `#if DEBUG`)

### 4.1 CasperCore — `DebugProtocol.swift`

- `DebugCommand` gains `target: String?` (nil = current-focus behavior) and the
  `Verb` enum gains `focus`.
- `DebugState.Surface` gains `id: String` (placed first in its member/init
  order for readable JSON).

### 4.2 CasperGhostty — `DebugServer.swift` / `GhosttyDemo.swift`

- `DebugSurfaceHandle` gains `id: String` and a `focus: () -> Void` closure.
- `DebugServer.resolve`:
  - New `.focus` case: resolve by `target` (required for `focus`), call the
    handle's `focus()`, return `.success()`.
  - `read-text` / `send-text` / `screenshot` resolve their target via a shared
    helper `target(in:matching:) -> DebugSurfaceHandle?` that returns the
    id-matched handle when `command.target` is set, otherwise `focusedOrFirst`.
    A set-but-unmatched target returns `.failure("no surface with id <id>")`
    (it must not silently fall back to the focused surface).
- `GhosttyDemo.debugSurfaces()` supplies `id: "0"` and
  `focus: { [weak view, weak window] in window?.makeFirstResponder(view) }`.

### 4.3 CasperCLI — `DebugCLICommand.swift`

- New `Focus` subcommand: `casper debug focus <id>` (`@Argument var id: String`),
  sends `DebugCommand(verb: .focus, target: id)`. **Non-retriable** — it has a
  UI side effect.
- `SendText` / `ReadText` / `Screenshot` gain `@Option var target: String?`,
  passed through as `DebugCommand(target:)`. The retry policy is unchanged:
  `dump-state` / `read-text` / `screenshot` remain retriable, `send-text`
  remains non-retriable; `--target` does not affect retriability.

## 5. Testing

- **CasperCore unit tests** (extend the existing `DebugProtocolTests`):
  - `DebugCommand` round-trip carrying `target` and `verb == .focus`.
  - `DebugState.Surface` round-trip carrying `id`.
- **Surface-bound behavior** (`focus`, `--target`, id in `dump-state`) is
  verified through the `debug-casper` GUI harness, consistent with the rest of
  the channel. **Honest limitation:** with a single surface today, the harness
  can exercise `focus 0`, `--target 0` (happy path), and `--target <unknown>`
  (error path), but not true multi-target selection — that arrives with Plan 5's
  multiple surfaces.

## 6. Out of Scope (recap)

- Non-terminal component addressing and a general component registry.
- Multi-window addressing beyond the surface id.
- `send-key` for modifier/special keys.
