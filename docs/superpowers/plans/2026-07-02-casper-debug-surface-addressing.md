# Casper Debug Surface Addressing & Focus — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the debug channel address a specific terminal surface by a stable id and change the UI focus deliberately — a `focus <id>` verb, a `--target <id>` option on the action verbs, and an `id` field in `dump-state`.

**Architecture:** Extends the existing `#if DEBUG` debug channel. `DebugCommand` gains a `target` field and a `focus` verb; `DebugState.Surface` gains an `id`; `DebugSurfaceHandle` gains an `id` and a `focus` closure; `DebugServer` resolves a verb's target surface (id-matched or focused-fallback) and handles `focus`; the CLI adds a `focus` subcommand and a `--target` option. The single-window demo exposes id `"0"`.

**Tech Stack:** Swift 6 / SwiftPM, `Network.framework` (existing transport), AppKit (`makeFirstResponder`), GhosttyKit (`ghostty_surface_set_focus` via `GhosttySurface.setFocus`), swift-argument-parser, XCTest.

## Global Constraints

- Target **macOS 14+, arm64-only**, Swift 6 (`swift-tools-version: 6.0`).
- **No new external dependencies.**
- **Everything added here is `#if DEBUG` only** and physically absent from
  `swift build -c release` (the files touched — `DebugProtocol.swift`,
  `DebugSocket.swift`'s siblings, `DebugServer.swift`, `DebugCLICommand.swift` —
  are already fully `#if DEBUG`; keep every addition inside those gates).
- **Target resolution rule:** a set-but-unmatched `--target`/`focus` id returns
  `.failure("no surface with id <id>")` and must **never** silently fall back to
  the focused surface. `--target` addresses a surface **without** changing UI
  focus; only the `focus` verb changes focus.
- Retry policy unchanged: `dump-state`/`read-text`/`screenshot` retriable;
  `send-text` and the new `focus` are **non-retriable** (they mutate).
- All generated text in **English, present tense**. Code ≤ 120 columns.
- XCTest needs the full Xcode toolchain; XCTest files using Foundation types
  must `import Foundation`. Build/test with
  `swift build --disable-automatic-resolution` /
  `swift test --disable-automatic-resolution` to reuse the extracted GhosttyKit
  xcframework (a plain build may re-download ~53 MB).

---

## File Structure

- `Sources/CasperCore/DebugProtocol.swift` — **Modify.** `DebugCommand.target`,
  `Verb.focus`, `DebugState.Surface.id`.
- `Tests/CasperCoreTests/DebugProtocolTests.swift` — **Modify.** Fix the existing
  `Surface.init` call; add round-trip tests for `target`/`focus`/`id`.
- `Sources/CasperGhostty/DebugServer.swift` — **Modify.** `DebugSurfaceHandle.id`
  + `focus`; `.focus` case; shared target resolution.
- `Sources/CasperGhostty/GhosttyDemo.swift` — **Modify.** Supply `id: "0"` and
  a `focus` closure in `debugSurfaces()`.
- `Sources/CasperCLI/DebugCLICommand.swift` — **Modify.** `Focus` subcommand;
  `--target` option on `ReadText`/`SendText`/`Screenshot`.
- `.claude/skills/debug-casper/SKILL.md` — **Modify.** Document `focus` and
  `--target`.

---

## Task 1: Protocol — `target`, `focus` verb, surface `id`

**Files:**
- Modify: `Sources/CasperCore/DebugProtocol.swift`
- Test: `Tests/CasperCoreTests/DebugProtocolTests.swift`

**Interfaces:**
- Produces:
  - `DebugCommand` gains `var target: String?` and init param `target: String? = nil`; `Verb` gains `case focus`.
  - `DebugState.Surface` gains `var id: String` (first member) and init param `id: String` (first param): `Surface(id:title:workingDirectory:columns:rows:focused:)`.

- [ ] **Step 1: Update the existing test call site and add failing tests**

In `Tests/CasperCoreTests/DebugProtocolTests.swift`, change the `Surface` init
inside `testResponseWithStateRoundTrip` from:

```swift
        let state = DebugState(surfaces: [
            .init(title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true),
        ])
```

to (add `id:` first):

```swift
        let state = DebugState(surfaces: [
            .init(id: "0", title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true),
        ])
```

Then add two new tests to the same class:

```swift
    func testCommandRoundTripWithTargetAndFocusVerb() throws {
        let command = DebugCommand(verb: .focus, target: "0")
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded.verb, .focus)
        XCTAssertEqual(decoded.target, "0")
    }

    func testSurfaceRoundTripCarriesId() throws {
        let surface = DebugState.Surface(
            id: "0", title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true)
        let data = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(DebugState.Surface.self, from: data)
        XCTAssertEqual(decoded.id, "0")
        XCTAssertEqual(decoded, surface)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --disable-automatic-resolution --filter CasperCoreTests.DebugProtocolTests`
Expected: FAIL — `DebugCommand` has no `target`, `Verb` has no `focus`, `Surface` has no `id` (compile errors).

- [ ] **Step 3: Add `target` + `focus` to `DebugCommand`**

In `Sources/CasperCore/DebugProtocol.swift`, in `DebugCommand`:

Add `case focus` to the `Verb` enum (after `screenshot`):

```swift
    public enum Verb: String, Codable, Sendable {
        case dumpState
        case readText
        case sendText
        case screenshot
        case focus
    }
```

Add the `target` stored property (after `path`):

```swift
    public var path: String?        // screenshot: output file path
    public var target: String?      // surface id to address (nil = focused/first)
```

Extend the initializer to accept and assign `target`:

```swift
    public init(
        verb: Verb, text: String? = nil, enter: Bool? = nil,
        scrollback: Bool? = nil, path: String? = nil, target: String? = nil
    ) {
        self.verb = verb
        self.text = text
        self.enter = enter
        self.scrollback = scrollback
        self.path = path
        self.target = target
    }
```

- [ ] **Step 4: Add `id` to `DebugState.Surface`**

In the same file, in `DebugState.Surface`, add `id` as the first member and
first init parameter:

```swift
    public struct Surface: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var workingDirectory: String?
        public var columns: Int
        public var rows: Int
        public var focused: Bool

        public init(
            id: String, title: String, workingDirectory: String?,
            columns: Int, rows: Int, focused: Bool
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.columns = columns
            self.rows = rows
            self.focused = focused
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --disable-automatic-resolution --filter CasperCoreTests.DebugProtocolTests`
Expected: PASS (the 3 original + 2 new = 5 tests). If CasperGhostty fails to
build here because `DebugState.Surface(...)`/`DebugSurfaceHandle` call sites are
now missing `id`, that is expected — Task 2 fixes them. Run the filtered
CasperCore test above (it builds only CasperCore) to confirm this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperCore/DebugProtocol.swift Tests/CasperCoreTests/DebugProtocolTests.swift
git commit -m "Add target field, focus verb, and surface id to the debug protocol"
```

---

## Task 2: `DebugServer` — surface id, focus closure, `.focus` case, target resolution

**Files:**
- Modify: `Sources/CasperGhostty/DebugServer.swift`
- Modify: `Sources/CasperGhostty/GhosttyDemo.swift`

**Interfaces:**
- Consumes: `DebugCommand.target`/`Verb.focus`, `DebugState.Surface(id:...)` (Task 1).
- Produces: `DebugSurfaceHandle` gains `let id: String` and `let focus: () -> Void`; init becomes `DebugSurfaceHandle(id:title:workingDirectory:focused:readText:sendText:columnsRows:focus:window:)`.

No unit test (drives live AppKit/libghostty on the main thread; verified by the
Task 4 GUI harness). Deliverable: builds in BOTH configs, then commit.

- [ ] **Step 1: Add `id` and `focus` to `DebugSurfaceHandle`**

In `Sources/CasperGhostty/DebugServer.swift`, extend the `DebugSurfaceHandle`
struct. Add `id` as the first stored property and `focus` after `columnsRows`;
update the initializer accordingly:

```swift
@MainActor
public struct DebugSurfaceHandle {
    public let id: String
    public let title: String
    public let workingDirectory: String?
    public let focused: Bool
    public let readText: (_ scrollback: Bool) -> String?
    public let sendText: (_ text: String) -> Void
    public let columnsRows: () -> (Int, Int)
    public let focus: () -> Void
    public let window: NSWindow?

    public init(
        id: String, title: String, workingDirectory: String?, focused: Bool,
        readText: @escaping (_ scrollback: Bool) -> String?,
        sendText: @escaping (_ text: String) -> Void,
        columnsRows: @escaping () -> (Int, Int),
        focus: @escaping () -> Void,
        window: NSWindow?
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.focused = focused
        self.readText = readText
        self.sendText = sendText
        self.columnsRows = columnsRows
        self.focus = focus
        self.window = window
    }
}
```

- [ ] **Step 2: Add target resolution and the `.focus` case in `resolve`**

In `DebugServer`, replace the whole `resolve(_:)` method with the version below.
It maps `id` into `dump-state`, routes `read-text`/`send-text`/`screenshot`
through a shared `target(in:matching:)`, and adds `.focus`:

```swift
    private func resolve(_ command: DebugCommand) -> DebugResponse {
        let surfaces = provider?.debugSurfaces() ?? []

        switch command.verb {
        case .dumpState:
            let entries = surfaces.map { handle -> DebugState.Surface in
                let (columns, rows) = handle.columnsRows()
                return DebugState.Surface(
                    id: handle.id, title: handle.title, workingDirectory: handle.workingDirectory,
                    columns: columns, rows: rows, focused: handle.focused)
            }
            return .success(state: DebugState(surfaces: entries))

        case .readText:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = handle.readText(command.scrollback ?? false) else {
                return .failure("read-text unavailable")
            }
            return .success(text: text)

        case .sendText:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = command.text else { return .failure("missing text") }
            handle.sendText(command.enter == true ? text + "\n" : text)
            return .success()

        case .screenshot:
            guard let path = command.path else { return .failure("missing path") }
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let window = handle.window else { return .failure("no window") }
            return screenshot(window: window, to: path)

        case .focus:
            guard let id = command.target else { return .failure("missing target id") }
            guard let handle = surfaces.first(where: { $0.id == id }) else {
                return .failure("no surface with id \(id)")
            }
            handle.focus()
            return .success()
        }
    }

    /// The surface a verb acts on: the id-matched surface when `target` is set,
    /// otherwise the focused surface (falling back to the first). A set-but-
    /// unmatched target returns nil — never a silent fallback.
    private func target(
        in surfaces: [DebugSurfaceHandle], matching target: String?
    ) -> DebugSurfaceHandle? {
        if let target { return surfaces.first(where: { $0.id == target }) }
        return focusedOrFirst(surfaces)
    }

    /// The failure for an unresolved target: id-specific when a target was
    /// given, generic when none was.
    private func targetFailure(_ target: String?) -> DebugResponse {
        if let target { return .failure("no surface with id \(target)") }
        return .failure("no surface")
    }
```

Keep the existing `focusedOrFirst(_:)` and `screenshot(window:to:)` methods
unchanged.

- [ ] **Step 3: Supply `id` and `focus` from the demo provider**

In `Sources/CasperGhostty/GhosttyDemo.swift`, replace the `debugSurfaces()`
body in the `DebugSurfaceProvider` extension with:

```swift
    func debugSurfaces() -> [DebugSurfaceHandle] {
        guard let view = surfaceView, view.debugHasSurface else { return [] }
        let window = self.window
        let focused = (window?.firstResponder === view)
        return [
            DebugSurfaceHandle(
                id: "0",
                title: window?.title ?? "casper",
                workingDirectory: directory,
                focused: focused,
                readText: { [weak view] scrollback in view?.debugReadText(scrollback: scrollback) },
                sendText: { [weak view] text in view?.debugSendText(text) },
                columnsRows: { [weak view] in view?.debugColumnsRows() ?? (0, 0) },
                focus: { [weak window, weak view] in window?.makeFirstResponder(view) },
                window: window),
        ]
    }
```

- [ ] **Step 4: Build both configurations**

Run: `swift build --disable-automatic-resolution && swift build -c release --disable-automatic-resolution`
Expected: both succeed. (Release still omits the whole `#if DEBUG` channel.)

- [ ] **Step 5: Run the full CasperCore + CasperGhostty tests (no regressions)**

Run: `swift test --disable-automatic-resolution --filter CasperCoreTests.DebugProtocolTests`
Expected: PASS (5 tests). CasperGhostty has no unit tests for these
surface-bound paths; the build in Step 4 is the compile gate.

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperGhostty/DebugServer.swift Sources/CasperGhostty/GhosttyDemo.swift
git commit -m "Resolve debug verbs by surface id and add a focus verb in DebugServer"
```

---

## Task 3: CLI — `focus` subcommand and `--target` option

**Files:**
- Modify: `Sources/CasperCLI/DebugCLICommand.swift`

**Interfaces:**
- Consumes: `DebugCommand(verb:...:target:)` and `Verb.focus` (Task 1).
- Produces: `casper debug focus <id>`; `--target <id>` on `read-text`/`send-text`/`screenshot`.

- [ ] **Step 1: Register the `Focus` subcommand**

In `Sources/CasperCLI/DebugCLICommand.swift`, add `Focus.self` to the root
subcommand list:

```swift
        subcommands: [DumpState.self, ReadText.self, SendText.self, Screenshot.self, Focus.self])
```

- [ ] **Step 2: Add `--target` to `ReadText`**

Add the option and thread it into the command. Replace the `ReadText` struct
body with:

```swift
    struct ReadText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the terminal's text.")
        @OptionGroup var socket: SocketOption
        @Flag(name: .long, help: "Include scrollback (full screen), not just the viewport.")
        var scrollback = false
        @Option(name: .long, help: "Surface id to read (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Idempotent: re-reading text is safe, so allow a bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .readText, scrollback: scrollback, target: target),
                socket: socket.path, retriable: true)
            print(response.text ?? "")
        }
    }
```

- [ ] **Step 3: Add `--target` to `SendText`**

```swift
    struct SendText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inject text into a surface.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to send.") var text: String
        @Flag(name: .long, help: "Append a trailing newline (press Return).")
        var enter = false
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Mutating: retrying could inject the text more than once, so never
            // retry this verb.
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter, target: target),
                socket: socket.path, retriable: false)
        }
    }
```

- [ ] **Step 4: Add `--target` to `Screenshot`**

```swift
    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String
        @Option(name: .long, help: "Surface id to capture (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Idempotent: re-capturing overwrites the same PNG, so allow a
            // bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .screenshot, path: path, target: target),
                socket: socket.path, retriable: true)
            print(response.text ?? path)
        }
    }
```

- [ ] **Step 5: Add the `Focus` subcommand**

Append inside the `extension DebugCLICommand { ... }` block, after `Screenshot`:

```swift
    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give UI focus to a surface by id.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Surface id to focus (see dump-state).") var id: String

        func run() throws {
            // Mutating (changes UI focus): never retry.
            _ = try CasperCLI.run(
                DebugCommand(verb: .focus, target: id), socket: socket.path, retriable: false)
        }
    }
```

- [ ] **Step 6: Build and verify the CLI surface**

Run:
```bash
swift build --disable-automatic-resolution
.build/debug/casper debug --help | grep -E 'focus|read-text|send-text|screenshot|dump-state'
.build/debug/casper debug read-text --help | grep -- --target
```
Expected: `debug --help` lists `focus` among the subcommands; `read-text --help`
shows a `--target` option. (Argument-parser derives `focus` from the `Focus`
type name.)

- [ ] **Step 7: Verify absence from release + no CLI-test regressions**

Run:
```bash
swift build -c release --disable-automatic-resolution
.build/release/casper debug focus 0; echo "exit=$?"
swift test --disable-automatic-resolution --filter CasperCLITests
```
Expected: release build succeeds; `casper debug focus 0` in release exits
non-zero with an "unexpected argument" error (subcommand absent); CasperCLITests
still pass (11 tests).

- [ ] **Step 8: Commit**

```bash
git add Sources/CasperCLI/DebugCLICommand.swift
git commit -m "Add casper debug focus subcommand and --target option to action verbs"
```

---

## Task 4: Runbook update + end-to-end verification

**Files:**
- Modify: `.claude/skills/debug-casper/SKILL.md`

**Interfaces:**
- Consumes: everything above (`casper debug focus`, `--target`, `id` in `dump-state`).

- [ ] **Step 1: Document `focus` and `--target` in the runbook**

In `.claude/skills/debug-casper/SKILL.md`, add a new section after the "Drive"
section (before "Teardown"), and update the Notes list. Insert:

```markdown
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
```

Add to the Notes list a bullet:

```markdown
- `--target <id>` addresses a surface without changing focus; `focus <id>`
  changes the UI focus. `focus` is not retried (it mutates UI state).
```

Keep Markdown ≤ 80 columns and fenced blocks tagged `bash`.

- [ ] **Step 2: End-to-end verification (manual GUI harness)**

Run (uses `/usr/bin/log` to avoid the zsh `log` builtin shadowing it):

```bash
make build
rm -f /tmp/casper-debug.sock
.build/debug/casper >/tmp/casper.out 2>&1 &
until [ -S /tmp/casper-debug.sock ]; do sleep 0.2; done

# id is present and equals "0"
.build/debug/casper debug dump-state | grep -E '"id"[[:space:]]*:[[:space:]]*"0"'
# addressing the known surface works
.build/debug/casper debug send-text 'echo target-ok' --enter --target 0
sleep 1
.build/debug/casper debug read-text --target 0 | grep -c target-ok
# focus verb succeeds and dump-state shows focused:true
.build/debug/casper debug focus 0; echo "focus exit=$?"
.build/debug/casper debug dump-state | grep -E '"focused"[[:space:]]*:[[:space:]]*true'
# unknown id fails cleanly, no fallback
.build/debug/casper debug read-text --target 99; echo "unknown-target exit=$?"

kill %1 2>/dev/null; rm -f /tmp/casper-debug.sock
```

Expected: `dump-state` shows `"id" : "0"`; `read-text --target 0` contains
`target-ok` (count ≥ 1); `focus 0` exits 0 and `dump-state` shows
`"focused" : true`; `read-text --target 99` prints
`error: no surface with id 99` to stderr and exits non-zero.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/debug-casper/SKILL.md
git commit -m "Document surface addressing and focus in the debug-casper runbook"
```

---

## Self-Review Notes

- **Spec coverage:** §3.1 surface id → Task 1 (`Surface.id`) + Task 2
  (dump-state mapping, provider `id: "0"`); §3.2 `focus` verb → Task 1
  (`Verb.focus`) + Task 2 (`.focus` case, `focus` closure) + Task 3 (`Focus`
  subcommand); §3.3 `--target` → Task 1 (`DebugCommand.target`) + Task 2
  (`target(in:matching:)`, no silent fallback) + Task 3 (`--target` options);
  §4 module changes → Tasks 1–3; §5 tests → Task 1 (Codable round-trips) + Task
  4 (GUI harness, incl. unknown-id error path).
- **Non-fallback rule** enforced in `target(in:matching:)`/`targetFailure`
  (Task 2) and asserted by the `read-text --target 99` E2E step (Task 4).
- **Retry policy:** `focus` and `send-text` non-retriable; `--target` does not
  change retriability (Task 3).
- **Gating:** all edits are inside pre-existing `#if DEBUG` files; release
  absence re-checked in Task 2 Step 4 and Task 3 Step 7.
- Note: `dump-state` CLI output uses `.sortedKeys`, so JSON keys render
  alphabetically regardless of struct member order; `id` is present but not
  necessarily first in the printed output. This is cosmetic and expected.
