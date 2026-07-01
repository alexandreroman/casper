# CLI + Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status: ✅ COMPLETE — 2026-07-01.** All 12 tasks implemented
> (subagent-driven, one `code-writer` per task), reviewed in clusters
> (`code-reviewer`), and committed on `main`. **89 XCTest tests pass**
> (`make test`, verified). Repo is **local-only — not pushed** to GitHub yet.
> Plan-3 code range: `fada198..29eabc5` (plan doc `143691d`).
>
> **Deviations from the plan as written (all applied, verified green):**
> - **Swift 6 strict concurrency (Tasks 8–9):** the plan's literal socket code did
>   not compile. `HookSocketServer` is `final class … : @unchecked Sendable` (an
>   actor would force an async API and break the fixed synchronous interface) with
>   the mutable-buffer recursion replaced by a by-value `receiveChunk(on:accumulated:)`;
>   `HookSocketClient` threads its error through `OSAllocatedUnfairLock<Error?>`
>   (`import os`) instead of a bare `var` in a `@Sendable` closure (no `@unchecked`
>   needed). Public interfaces and one-message-per-connection semantics unchanged.
>   See [[swift6-network-concurrency]].
> - **CLI hooks command family (Task 11):** instead of a top-level
>   `casper hook` relay + separate install, Casper now provides a `hooks`
>   family — a plural **`hooks`** group with plain subcommands `casper hooks setup`
>   (install) and `casper hooks feed` (relay). The generated `settings.local.json`
>   invokes `casper hooks feed` explicitly, so `feed` is a normal subcommand (no
>   default-subcommand trick). `ClaudeCodeAdapter`'s embedded command string
>   changed `"casper hook"` → `"casper hooks feed"`. Task 11's code blocks below
>   reflect the final design; Task 10 built the relay as `HookCommand`, renamed to
>   `HooksFeedCommand` in Task 11 (`git mv`).
> - **Install once, not per terminal (design refinement):** installing the hooks
>   file is a one-time `casper hooks setup` action per worktree, NOT run on every
>   terminal open; only the surface *environment* is injected per surface. See
>   [[hooks-install-once]]. This supersedes the design spec §7 wording ("installed
>   when a terminal surface is created").
> - **Doc-comment sweep (`05bb1aa`):** four stale `casper hook` doc comments in
>   `CasperAgents` updated to `casper hooks feed`.
> - **No global `casper` install (design refinement):** the design spec's
>   `~/.local/bin/casper` shim (§4) is dropped. `casper` need only be reachable
>   inside terminals Casper opens, so `ClaudeCodeAdapter.surfaceEnvironment` gains
>   optional `casperDirectory`/`basePath` params and prepends the binary's dir to
>   `PATH`; the hook command stays the relative `casper hooks feed`. Plan 5 passes
>   the app bundle's executable dir. See [[casper-cli-availability]].
>
> **Deferred to Plan 5 / later (documented, non-blocking):** the real GUI; the
> heartbeat *timer* that calls `HeartbeatMonitor` +
> `markUnknown` (the pure logic and transitions ship here); `casper open` /
> `casper worktree` subcommands; optional `--agent` / per-agent `hooks <agent>
> install` (v1 is Claude-only); Plan 5 wiring the real bundle dir into
> `surfaceEnvironment(casperDirectory:basePath:)`. **Socket robustness follow-ups
> from the Task 8–9 review (address before Plan 5 wires `onMessage` →
> `AgentStateStore`):**
> `stop()` does not cancel in-flight `NWConnection`s (post-stop `onMessage`
> possible); no per-connection read timeout / receive-buffer cap; the
> `onMessage`/`onFailure` "set before `start()`" contract is prose-only.

**Goal:** Ship the `casper` single binary with a `casper hook` subcommand that
relays Claude Code hook events over a Unix-domain socket into a per-workspace
`AgentStateStore`, plus the Claude Code adapter that installs those hooks and the
surface environment.

**Architecture:** Claude Code (running in a terminal surface) fires hooks that
invoke `casper hook`; that CLI reads the hook JSON on stdin, wraps it with the
surface's `CASPER_WORKSPACE_ID`, and sends it over `CASPER_SOCKET` (a Unix-domain
socket) to a `HookSocketServer`. The server decodes each message with the
existing `HookEventParser` and drives an `AgentStateStore`, which owns the
per-workspace state machine (wrapping the pure `AgentStateReducer` from Plan 1)
plus the `unknown`/`error` transitions the spec defers to this plan. The
`CasperAgents` module owns the wire envelope, the socket transport, and the
Claude Code adapter (`settings.local.json` + surface env). `CasperCLI` owns the
argument-parser command tree and the GUI/CLI launch fork. A new `casper`
executable target wires them together; GUI mode is a stub until Plan 5.

**Tech Stack:** Swift 6 / SwiftPM, `swift-argument-parser` (new dependency,
Apple), `Network.framework` (Unix-domain socket), `Foundation`. Existing
`CasperCore` (`HookEvent`, `HookEventParser`, `AgentStateReducer`, `Workspace`,
`Todo`, `AgentEffect`).

## Global Constraints

- **Platform:** macOS 14+, **arm64-only**. Swift 6 tools (`swift-tools-version:
  6.0`), Swift 6 language mode (all public types crossing concurrency boundaries
  stay `Sendable` where the existing code already is).
- **Dependencies:** only the three sanctioned externals may be added. This plan
  adds exactly one: **`swift-argument-parser`** (Apple). No other third-party
  packages. The socket uses **`Network.framework`** (system); persistence/JSON
  use **`Foundation`** (system).
- **Line length:** code 120 columns, Markdown 80 columns. Fenced code blocks
  carry a language tag.
- **English only** for all identifiers, comments, docs, and user-facing text.
- **Never crash on a hook.** `casper hook` must exit 0 and never block the agent,
  even when the socket is missing, unreachable, or the env is absent.
- **Tests:** XCTest, run via `make test` (needs the full Xcode toolchain). New
  `import Foundation` explicitly in any XCTest file using Foundation types.
- **Build/verify:** `make build` (compile) and `make test` (suite). Requires
  `brew install libgit2 pkgconf` (already documented from Plan 2).
- **Git:** get explicit authorization before committing. Commit messages are in
  English, verb + action performed.

---

## File Structure

New and modified files, by responsibility:

- `Package.swift` *(modify)* — add `swift-argument-parser` dependency; add
  `CasperAgents`, `CasperCLI` library targets, the `casper` executable target,
  and the `CasperAgentsTests` / `CasperCLITests` test targets.
- `Sources/CasperCore/AgentStateStore.swift` *(create)* — stateful per-workspace
  owner of the reducer; `handle`, `markUnknown`, `markError`, `onChange`.
- `Sources/CasperCore/HeartbeatMonitor.swift` *(create)* — pure helper computing
  which workspaces are stale (feeds `markUnknown` in Plan 5's timer).
- `Sources/CasperAgents/CasperAgents.swift` *(create then trim)* — module version
  marker (scaffolding; keeps SwiftPM happy until real sources land).
- `Sources/CasperAgents/HookMessage.swift` *(create)* — Codable wire envelope
  `{ workspaceId, hookPayload }`.
- `Sources/CasperAgents/ClaudeCodeAdapter.swift` *(create)* — `settings.local.json`
  generation, surface environment, install-into-worktree.
- `Sources/CasperAgents/HookSocket.swift` *(create)* — `HookSocketServer`
  (listener) and `HookSocketClient` (one-shot sender).
- `Sources/CasperCLI/LaunchMode.swift` *(create)* — GUI/CLI argv fork (testable).
- `Sources/CasperCLI/HookCommand.swift` *(create)* — `casper hook` subcommand.
- `Sources/CasperCLI/CasperCommand.swift` *(create)* — root `ParsableCommand`.
- `Sources/casper/main.swift` *(create then rewrite)* — executable entry point.
- `Tests/CasperCoreTests/AgentStateStoreTests.swift` *(create)*
- `Tests/CasperCoreTests/HeartbeatMonitorTests.swift` *(create)*
- `Tests/CasperAgentsTests/HookMessageTests.swift` *(create)*
- `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift` *(create)*
- `Tests/CasperAgentsTests/HookSocketTests.swift` *(create)*
- `Tests/CasperCLITests/LaunchModeTests.swift` *(create)*
- `Tests/CasperCLITests/HookCommandTests.swift` *(create)*
- `Tests/CasperCLITests/EndToEndHookTests.swift` *(create)*

**Scope boundaries (out of this plan):** wiring the real app-bundle executable
dir into `surfaceEnvironment(casperDirectory:basePath:)` (Plan 5 — this plan
ships the capability + tests; there is **no** global `~/.local/bin/casper`
shim); the real GUI (Plan 5); the timer that periodically calls
`HeartbeatMonitor` + `markUnknown` (wired in Plan 5 — this plan ships the pure
logic and the transition). `casper open` / `casper worktree` subcommands are
deferred to a later plan; only the `casper hooks` family ships here.

---

## Task 1: Scaffold targets and the argument-parser dependency

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CasperAgents/CasperAgents.swift`
- Create: `Sources/CasperCLI/CasperCLI.swift`
- Create: `Sources/casper/main.swift`
- Create: `Tests/CasperAgentsTests/CasperAgentsVersionTests.swift`

**Interfaces:**
- Produces: module targets `CasperAgents`, `CasperCLI`, executable `casper`, test
  targets `CasperAgentsTests`, `CasperCLITests`. Public constant
  `CasperAgents.casperAgentsVersion: String`.

SwiftPM 6 rejects a product/target with no compilable source, so each new target
gets a minimal real source in this task (the same pattern Plan 2 used). The
`main.swift` and `CasperCLI.swift` placeholders are rewritten in later tasks.

- [ ] **Step 1: Add the dependency and targets to `Package.swift`**

Replace the whole file with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CasperCore", targets: ["CasperCore"]),
        .library(name: "CasperGit", targets: ["CasperGit"]),
        .library(name: "CasperAgents", targets: ["CasperAgents"]),
        .library(name: "CasperCLI", targets: ["CasperCLI"]),
        .executable(name: "casper", targets: ["casper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            from: "1.5.0"
        ),
    ],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(name: "CasperGit", dependencies: ["Clibgit2"]),
        .target(name: "CasperCore", dependencies: ["CasperGit"]),
        .target(name: "CasperAgents", dependencies: ["CasperCore"]),
        .target(
            name: "CasperCLI",
            dependencies: [
                "CasperCore",
                "CasperAgents",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "casper", dependencies: ["CasperCLI"]),
        .testTarget(
            name: "CasperGitTests",
            dependencies: ["CasperGit", "Clibgit2"]
        ),
        .testTarget(
            name: "CasperCoreTests",
            dependencies: ["CasperCore", "Clibgit2"]
        ),
        .testTarget(
            name: "CasperAgentsTests",
            dependencies: ["CasperAgents", "CasperCore"]
        ),
        .testTarget(
            name: "CasperCLITests",
            dependencies: ["CasperCLI", "CasperAgents", "CasperCore"]
        ),
    ]
)
```

- [ ] **Step 2: Create the module placeholders**

`Sources/CasperAgents/CasperAgents.swift`:

```swift
/// Version marker for the CasperAgents module (Claude Code adapter + hook socket).
public let casperAgentsVersion = "0.1.0"
```

`Sources/CasperCLI/CasperCLI.swift`:

```swift
// CasperCLI: swift-argument-parser command tree and the GUI/CLI launch fork.
// Real sources land in later tasks; this comment keeps the target compilable.
```

`Sources/casper/main.swift`:

```swift
// Placeholder entry point; rewritten in Task 11 to fork GUI vs CLI.
import Foundation

FileHandle.standardError.write(Data("casper: not yet wired\n".utf8))
```

- [ ] **Step 3: Write the failing test**

`Tests/CasperAgentsTests/CasperAgentsVersionTests.swift`:

```swift
import XCTest
@testable import CasperAgents

final class CasperAgentsVersionTests: XCTestCase {
    func testModuleVersionIsSet() {
        XCTAssertEqual(casperAgentsVersion, "0.1.0")
    }
}
```

- [ ] **Step 4: Run the build and test**

Run: `swift build`
Expected: PASS (resolves `swift-argument-parser`, compiles all targets).

Run: `swift test --filter CasperAgentsVersionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved Sources/CasperAgents Sources/CasperCLI Sources/casper Tests/CasperAgentsTests
git commit -m "Scaffold CasperAgents, CasperCLI, and the casper executable"
```

---

## Task 2: AgentStateStore — event handling

**Files:**
- Create: `Sources/CasperCore/AgentStateStore.swift`
- Test: `Tests/CasperCoreTests/AgentStateStoreTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `HookEvent`, `AgentEffect`, `AgentStateReducer.apply`
  (all existing in CasperCore).
- Produces:
  - `final class AgentStateStore`
    - `init(workspaces: [Workspace] = [])`
    - `private(set) var workspaces: [Workspace]`
    - `var onChange: ((Workspace) -> Void)?`
    - `func workspace(id: UUID) -> Workspace?`
    - `@discardableResult func handle(_ event: HookEvent, workspaceId: UUID, focused: Bool) -> AgentEffect?`

The store is a plain class (thread-confinement is the caller's job; Plan 5 drives
it from the main actor). It is the "state machine" the design names, wrapping the
pure reducer over a keyed collection and emitting `onChange` for the UI.

- [ ] **Step 1: Write the failing test**

`Tests/CasperCoreTests/AgentStateStoreTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class AgentStateStoreTests: XCTestCase {
    private func makeWorkspace(name: String = "ws") -> Workspace {
        Workspace(
            name: name, repoPath: "/repo", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0))
    }

    func testHandleSessionStartSetsRunning() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        let effect = store.handle(.sessionStart, workspaceId: ws.id, focused: true)
        XCTAssertNil(effect)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .running)
    }

    func testHandleStopUnfocusedReturnsNotifyEffect() {
        let ws = makeWorkspace(name: "feature")
        let store = AgentStateStore(workspaces: [ws])
        let effect = store.handle(.stop, workspaceId: ws.id, focused: false)
        XCTAssertEqual(effect, .notify(title: "feature", body: "Agent finished"))
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .done)
        XCTAssertEqual(store.workspace(id: ws.id)?.pendingNotification, true)
    }

    func testHandleTodoUpdateStoresTodos() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        let todos = [Todo(content: "a", status: .inProgress)]
        store.handle(.todoUpdate(todos: todos), workspaceId: ws.id, focused: true)
        XCTAssertEqual(store.workspace(id: ws.id)?.todos, todos)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .running)
    }

    func testHandleUnknownWorkspaceIsNoOp() {
        let store = AgentStateStore(workspaces: [makeWorkspace()])
        let effect = store.handle(.stop, workspaceId: UUID(), focused: false)
        XCTAssertNil(effect)
    }

    func testOnChangeFiresWithMutatedWorkspace() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        var changed: Workspace?
        store.onChange = { changed = $0 }
        store.handle(.sessionStart, workspaceId: ws.id, focused: true)
        XCTAssertEqual(changed?.agentState, .running)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentStateStoreTests`
Expected: FAIL — `cannot find 'AgentStateStore' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/CasperCore/AgentStateStore.swift`:

```swift
import Foundation

/// The stateful, per-workspace owner of the agent state machine. It wraps the
/// pure `AgentStateReducer` over a keyed collection of workspaces and reports
/// mutations through `onChange` so a UI can react. Thread-confinement is the
/// caller's responsibility (Plan 5 drives it from the main actor).
public final class AgentStateStore {
    public private(set) var workspaces: [Workspace]

    /// Invoked with the mutated workspace after any state change.
    public var onChange: ((Workspace) -> Void)?

    public init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }

    public func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// Apply a hook event to the identified workspace. Returns the reducer's
    /// side effect (e.g. a notification), or `nil` when there is none or the
    /// workspace is unknown.
    @discardableResult
    public func handle(
        _ event: HookEvent, workspaceId: UUID, focused: Bool
    ) -> AgentEffect? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId })
        else { return nil }
        let effect = AgentStateReducer.apply(
            event, to: &workspaces[index], focused: focused)
        onChange?(workspaces[index])
        return effect
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentStateStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/AgentStateStore.swift Tests/CasperCoreTests/AgentStateStoreTests.swift
git commit -m "Add AgentStateStore wrapping the reducer over a workspace collection"
```

---

## Task 3: AgentStateStore unknown/error transitions + HeartbeatMonitor

**Files:**
- Modify: `Sources/CasperCore/AgentStateStore.swift`
- Create: `Sources/CasperCore/HeartbeatMonitor.swift`
- Modify: `Tests/CasperCoreTests/AgentStateStoreTests.swift`
- Create: `Tests/CasperCoreTests/HeartbeatMonitorTests.swift`

**Interfaces:**
- Consumes: `AgentStateStore` (Task 2), `AgentState`.
- Produces:
  - `AgentStateStore.markUnknown(workspaceId: UUID)`
  - `AgentStateStore.markError(workspaceId: UUID)`
  - `enum HeartbeatMonitor { static func staleWorkspaces(lastSeen: [UUID: Date], now: Date, timeout: TimeInterval) -> [UUID] }`

These are the `unknown`/`error` transitions the design defers from the pure Plan 1
reducer to this plan. `markUnknown` is meant to be called by Plan 5's heartbeat
timer (using `HeartbeatMonitor`); `markError` by the socket owner on transport
failure. Both are pure state transitions here.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CasperCoreTests/AgentStateStoreTests.swift` (inside the class):

```swift
    func testMarkUnknownSetsUnknownState() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        store.markUnknown(workspaceId: ws.id)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .unknown)
    }

    func testMarkErrorSetsErrorStateAndFiresOnChange() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        var changed: Workspace?
        store.onChange = { changed = $0 }
        store.markError(workspaceId: ws.id)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .error)
        XCTAssertEqual(changed?.agentState, .error)
    }

    func testMarkUnknownForMissingWorkspaceIsNoOp() {
        let store = AgentStateStore(workspaces: [makeWorkspace()])
        var fired = false
        store.onChange = { _ in fired = true }
        store.markUnknown(workspaceId: UUID())
        XCTAssertFalse(fired)
    }
```

`Tests/CasperCoreTests/HeartbeatMonitorTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class HeartbeatMonitorTests: XCTestCase {
    func testWorkspacesPastTimeoutAreStale() {
        let old = UUID(), fresh = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let lastSeen = [
            old: Date(timeIntervalSince1970: 900),   // 100s ago
            fresh: Date(timeIntervalSince1970: 990),  // 10s ago
        ]
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: lastSeen, now: now, timeout: 30)
        XCTAssertEqual(stale, [old])
    }

    func testExactlyAtTimeoutIsNotStale() {
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1000)
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: [id: Date(timeIntervalSince1970: 970)], now: now, timeout: 30)
        XCTAssertTrue(stale.isEmpty)
    }

    func testEmptyInputYieldsNoStale() {
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: [:], now: Date(), timeout: 30)
        XCTAssertTrue(stale.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HeartbeatMonitorTests`
Expected: FAIL — `cannot find 'HeartbeatMonitor' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/CasperCore/AgentStateStore.swift` (inside the class, after
`handle`):

```swift
    /// Transition to `unknown` — no hook activity within the heartbeat window.
    /// Intended to be driven by `HeartbeatMonitor` from the app's timer (Plan 5).
    public func markUnknown(workspaceId: UUID) {
        setState(.unknown, workspaceId: workspaceId)
    }

    /// Transition to `error` — the socket owner detected a broken transport.
    public func markError(workspaceId: UUID) {
        setState(.error, workspaceId: workspaceId)
    }

    private func setState(_ state: AgentState, workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId })
        else { return }
        workspaces[index].agentState = state
        onChange?(workspaces[index])
    }
```

`Sources/CasperCore/HeartbeatMonitor.swift`:

```swift
import Foundation

/// Pure helper deciding which workspaces have gone silent. The app's periodic
/// timer (Plan 5) feeds the result to `AgentStateStore.markUnknown`. Kept pure
/// (clock injected as `now`) so it is testable without real time.
public enum HeartbeatMonitor {
    /// Workspace ids whose most recent activity is strictly older than
    /// `now - timeout`. A workspace exactly at the boundary is not yet stale.
    public static func staleWorkspaces(
        lastSeen: [UUID: Date], now: Date, timeout: TimeInterval
    ) -> [UUID] {
        lastSeen
            .filter { now.timeIntervalSince($0.value) > timeout }
            .map(\.key)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AgentStateStoreTests`
Expected: PASS (8 tests).

Run: `swift test --filter HeartbeatMonitorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/AgentStateStore.swift Sources/CasperCore/HeartbeatMonitor.swift Tests/CasperCoreTests/AgentStateStoreTests.swift Tests/CasperCoreTests/HeartbeatMonitorTests.swift
git commit -m "Add unknown/error transitions and the pure HeartbeatMonitor"
```

---

## Task 4: HookMessage wire envelope

**Files:**
- Create: `Sources/CasperAgents/HookMessage.swift`
- Test: `Tests/CasperAgentsTests/HookMessageTests.swift`

**Interfaces:**
- Produces:
  - `struct HookMessage: Codable, Equatable, Sendable`
    - `let workspaceId: UUID`
    - `let hookPayload: Data` (the raw hook JSON as read from stdin)
    - `init(workspaceId: UUID, hookPayload: Data)`

`hookPayload` carries the raw hook JSON verbatim so the server can reuse the
existing `HookEventParser`. `JSONEncoder` encodes `Data` as base64, which
round-trips cleanly over the socket.

- [ ] **Step 1: Write the failing test**

`Tests/CasperAgentsTests/HookMessageTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperAgents

final class HookMessageTests: XCTestCase {
    func testJSONRoundTripPreservesFields() throws {
        let payload = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = HookMessage(workspaceId: UUID(), hookPayload: payload)
        let encoded = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(HookMessage.self, from: encoded)
        XCTAssertEqual(decoded, message)
        XCTAssertEqual(decoded.hookPayload, payload)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookMessageTests`
Expected: FAIL — `cannot find 'HookMessage' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/CasperAgents/HookMessage.swift`:

```swift
import Foundation

/// The wire envelope `casper hook` sends to the app: a workspace id plus the raw
/// Claude Code hook JSON, so the receiver can decode it with `HookEventParser`.
public struct HookMessage: Codable, Equatable, Sendable {
    public let workspaceId: UUID
    public let hookPayload: Data

    public init(workspaceId: UUID, hookPayload: Data) {
        self.workspaceId = workspaceId
        self.hookPayload = hookPayload
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookMessageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/HookMessage.swift Tests/CasperAgentsTests/HookMessageTests.swift
git commit -m "Add HookMessage wire envelope for the hook socket"
```

---

## Task 5: ClaudeCodeAdapter — settings.local.json generation

**Files:**
- Create: `Sources/CasperAgents/ClaudeCodeAdapter.swift`
- Test: `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift`

**Interfaces:**
- Produces:
  - `enum ClaudeCodeAdapter`
    - `static func settingsJSON(hookCommand: String = "casper hook") throws -> Data`

Emits the Claude Code hooks config wiring `SessionStart`, `Stop`, `Notification`,
and `PostToolUse` (matcher `TodoWrite`) to `hookCommand`. Claude Code delivers the
hook JSON (including `hook_event_name`) on stdin, so one command serves every
event. We target `.claude/settings.local.json` (Task 7) — the project-local,
uncommitted settings file — which resolves the spec's §15 open question without
polluting the user's repo.

- [ ] **Step 1: Write the failing test**

`Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperAgents

final class ClaudeCodeAdapterTests: XCTestCase {
    private func hooksObject() throws -> [String: Any] {
        let data = try ClaudeCodeAdapter.settingsJSON()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hooks"] as? [String: Any])
    }

    func testSettingsWireAllFourEvents() throws {
        let hooks = try hooksObject()
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["PostToolUse"])
    }

    func testPostToolUseMatchesTodoWrite() throws {
        let hooks = try hooksObject()
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.first?["matcher"] as? String, "TodoWrite")
    }

    func testHookCommandIsEmbedded() throws {
        let hooks = try hooksObject()
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["type"] as? String, "command")
        XCTAssertEqual(inner.first?["command"] as? String, "casper hook")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: FAIL — `cannot find 'ClaudeCodeAdapter' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/CasperAgents/ClaudeCodeAdapter.swift`:

```swift
import Foundation

/// Generates the Claude Code integration for a worktree: the hooks
/// `settings.local.json` and the surface environment. Confines all Claude
/// Code-specific knowledge to one place (v1 supports Claude Code only).
public enum ClaudeCodeAdapter {
    /// The `settings.local.json` body wiring Claude Code hooks to `hookCommand`.
    /// One command serves every event; Claude Code sends the hook JSON (with
    /// `hook_event_name`) on stdin. `PostToolUse` is filtered to `TodoWrite`.
    public static func settingsJSON(hookCommand: String = "casper hook") throws -> Data {
        func entry(matcher: String?) -> [String: Any] {
            var e: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand]],
            ]
            if let matcher { e["matcher"] = matcher }
            return e
        }

        let settings: [String: Any] = [
            "hooks": [
                "SessionStart": [entry(matcher: nil)],
                "Stop": [entry(matcher: nil)],
                "Notification": [entry(matcher: nil)],
                "PostToolUse": [entry(matcher: "TodoWrite")],
            ],
        ]

        return try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/ClaudeCodeAdapter.swift Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift
git commit -m "Generate Claude Code hooks settings.local.json"
```

---

## Task 6: ClaudeCodeAdapter — surface environment

**Files:**
- Modify: `Sources/CasperAgents/ClaudeCodeAdapter.swift`
- Modify: `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeAdapter` (Task 5).
- Produces:
  - `ClaudeCodeAdapter.surfaceEnvironment(socketPath: String, workspaceId: UUID, portBase: Int, blockSize: Int = 10) -> [String: String]`

Returns the environment injected into every terminal surface: `CASPER_SOCKET`,
`CASPER_WORKSPACE_ID`, `CASPER_PORT` (block base), and the convenience
`CASPER_PORT_0 … CASPER_PORT_9`.

- [ ] **Step 1: Write the failing tests**

Append to `ClaudeCodeAdapterTests` (inside the class):

```swift
    func testSurfaceEnvironmentCoreVariables() {
        let id = UUID()
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: id, portBase: 40010)
        XCTAssertEqual(env["CASPER_SOCKET"], "/tmp/casper.sock")
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40010")
    }

    func testSurfaceEnvironmentExposesTheWholeBlock() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: UUID(), portBase: 40010)
        XCTAssertEqual(env["CASPER_PORT_0"], "40010")
        XCTAssertEqual(env["CASPER_PORT_9"], "40019")
        XCTAssertNil(env["CASPER_PORT_10"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: FAIL — no `surfaceEnvironment` member.

- [ ] **Step 3: Write the implementation**

Append to `ClaudeCodeAdapter` (inside the enum):

```swift
    /// Environment injected into every terminal surface of a workspace so that
    /// `casper hook` can reach the app and the agent can bind its reserved
    /// ports. `CASPER_PORT` is the block base; `CASPER_PORT_0…9` expose the
    /// whole reserved block for convenience.
    public static func surfaceEnvironment(
        socketPath: String, workspaceId: UUID, portBase: Int, blockSize: Int = 10
    ) -> [String: String] {
        var env: [String: String] = [
            "CASPER_SOCKET": socketPath,
            "CASPER_WORKSPACE_ID": workspaceId.uuidString,
            "CASPER_PORT": String(portBase),
        ]
        for offset in 0..<blockSize {
            env["CASPER_PORT_\(offset)"] = String(portBase + offset)
        }
        return env
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/ClaudeCodeAdapter.swift Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift
git commit -m "Expose the surface environment for hooks and reserved ports"
```

---

## Task 7: ClaudeCodeAdapter — install into a worktree

**Files:**
- Modify: `Sources/CasperAgents/ClaudeCodeAdapter.swift`
- Modify: `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeAdapter.settingsJSON` (Task 5).
- Produces:
  - `ClaudeCodeAdapter.install(intoWorktreeAt worktreePath: String, hookCommand: String = "casper hook") throws`
  - `ClaudeCodeAdapter.settingsPath(inWorktreeAt worktreePath: String) -> String`

Writes `<worktree>/.claude/settings.local.json`, creating `.claude` if needed.
`settingsPath` is exposed so callers (and tests) can locate the file.

- [ ] **Step 1: Write the failing test**

Append to `ClaudeCodeAdapterTests` (inside the class):

```swift
    func testInstallWritesSettingsLocalJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)

        let path = ClaudeCodeAdapter.settingsPath(inWorktreeAt: dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".claude/settings.local.json"))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["hooks"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeAdapterTests/testInstallWritesSettingsLocalJSON`
Expected: FAIL — no `install` member.

- [ ] **Step 3: Write the implementation**

Append to `ClaudeCodeAdapter` (inside the enum):

```swift
    /// The path to the generated settings file inside a worktree.
    public static func settingsPath(inWorktreeAt worktreePath: String) -> String {
        URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude/settings.local.json").path
    }

    /// Write `.claude/settings.local.json` into the worktree, creating the
    /// `.claude` directory if needed. Uses the project-local (uncommitted)
    /// settings file so the user's repo is never polluted.
    public static func install(
        intoWorktreeAt worktreePath: String, hookCommand: String = "casper hook"
    ) throws {
        let claudeDir = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        let data = try settingsJSON(hookCommand: hookCommand)
        try data.write(
            to: claudeDir.appendingPathComponent("settings.local.json"),
            options: .atomic)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/ClaudeCodeAdapter.swift Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift
git commit -m "Install Claude Code hooks into a worktree"
```

---

## Task 8: HookSocketServer — Unix-domain listener

**Files:**
- Create: `Sources/CasperAgents/HookSocket.swift`
- Test: `Tests/CasperAgentsTests/HookSocketTests.swift` (server-only test here;
  the round-trip is completed in Task 9)

**Interfaces:**
- Consumes: `HookMessage` (Task 4), `Network.framework`.
- Produces:
  - `final class HookSocketServer`
    - `init(socketPath: String)`
    - `var onMessage: ((HookMessage) -> Void)?`
    - `var onFailure: ((Error) -> Void)?`
    - `func start() throws`
    - `func stop()`

One connection carries exactly one `HookMessage`: the client writes the JSON and
half-closes; the server accumulates bytes until EOF, decodes, and calls
`onMessage`. The listener binds a Unix-domain endpoint via `NWParameters` (TCP
options) + `requiredLocalEndpoint = .unix(path:)` + `allowLocalEndpointReuse`,
after unlinking any stale socket file. `onFailure` fires if the listener itself
fails (the socket owner may map that to `AgentStateStore.markError`).

- [ ] **Step 1: Write the failing test**

`Tests/CasperAgentsTests/HookSocketTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import CasperAgents

final class HookSocketTests: XCTestCase {
    /// A unique, short socket path under the temp dir (AF_UNIX paths are length
    /// limited, so avoid the long default temporaryDirectory when possible).
    private func tempSocketPath() -> String {
        "/tmp/casper-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testServerStartsAndStopsCleanly() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path)
        try server.start()
        server.stop()
        // A fresh server can rebind the same path after stop().
        let server2 = HookSocketServer(socketPath: path)
        try server2.start()
        server2.stop()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookSocketTests`
Expected: FAIL — `cannot find 'HookSocketServer' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/CasperAgents/HookSocket.swift`:

```swift
import Foundation
import Network

/// Listens on a Unix-domain socket for `HookMessage`s sent by `casper hook`.
/// One connection carries one message (client writes JSON, then half-closes);
/// the server reads to EOF, decodes, and invokes `onMessage`.
public final class HookSocketServer {
    private let socketPath: String
    private let queue = DispatchQueue(label: "casper.hook-socket.server")
    private var listener: NWListener?

    /// Called on the server queue with each decoded message.
    public var onMessage: ((HookMessage) -> Void)?
    /// Called on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onFailure?(error)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func readMore() {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { [weak self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if isComplete || error != nil {
                    self?.deliver(buffer)
                    connection.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func deliver(_ buffer: Data) {
        guard !buffer.isEmpty,
              let message = try? JSONDecoder().decode(HookMessage.self, from: buffer)
        else { return }
        onMessage?(message)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookSocketTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/HookSocket.swift Tests/CasperAgentsTests/HookSocketTests.swift
git commit -m "Add HookSocketServer listening on a Unix-domain socket"
```

---

## Task 9: HookSocketClient + round-trip integration

**Files:**
- Modify: `Sources/CasperAgents/HookSocket.swift`
- Modify: `Tests/CasperAgentsTests/HookSocketTests.swift`

**Interfaces:**
- Consumes: `HookSocketServer` (Task 8), `HookMessage` (Task 4).
- Produces:
  - `enum HookSocketClient`
    - `static func send(_ message: HookMessage, toSocketAt socketPath: String, timeout: TimeInterval = 2) throws`
  - `struct HookSocketError: Error, Equatable { let reason: String }`

The client is synchronous (a short-lived CLI): it connects, writes the JSON,
half-closes, and blocks on a semaphore until the send completes or `timeout`
elapses. Throwing lets the caller decide (`casper hook` swallows the error).

- [ ] **Step 1: Write the failing test**

Append to `HookSocketTests` (inside the class):

```swift
    func testClientToServerRoundTripDeliversMessage() throws {
        let path = tempSocketPath()
        let server = HookSocketServer(socketPath: path)
        let received = XCTestExpectation(description: "message received")
        let sentId = UUID()
        server.onMessage = { message in
            if message.workspaceId == sentId { received.fulfill() }
        }
        try server.start()
        defer { server.stop() }

        let payload = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
        try HookSocketClient.send(
            HookMessage(workspaceId: sentId, hookPayload: payload),
            toSocketAt: path)

        wait(for: [received], timeout: 5)
    }

    func testClientThrowsWhenSocketMissing() {
        let message = HookMessage(workspaceId: UUID(), hookPayload: Data())
        XCTAssertThrowsError(
            try HookSocketClient.send(
                message, toSocketAt: "/tmp/casper-nope-\(UUID().uuidString).sock",
                timeout: 1))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookSocketTests`
Expected: FAIL — `cannot find 'HookSocketClient' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/CasperAgents/HookSocket.swift`:

```swift
/// A transport failure sending a hook message.
public struct HookSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Sends a single `HookMessage` to the app's Unix-domain socket and returns once
/// the write completes. Synchronous by design: `casper hook` is short-lived.
public enum HookSocketClient {
    public static func send(
        _ message: HookMessage, toSocketAt socketPath: String,
        timeout: TimeInterval = 2
    ) throws {
        let data = try JSONEncoder().encode(message)

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            to: NWEndpoint.unix(path: socketPath), using: params)
        let queue = DispatchQueue(label: "casper.hook-socket.client")
        let done = DispatchSemaphore(value: 0)
        var sendError: Error?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, completion: .contentProcessed { error in
                    sendError = error
                    connection.cancel()
                    done.signal()
                })
            case .failed(let error):
                sendError = error
                connection.cancel()
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw HookSocketError(reason: "timed out sending to \(socketPath)")
        }
        if let sendError {
            throw HookSocketError(reason: "\(sendError)")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookSocketTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperAgents/HookSocket.swift Tests/CasperAgentsTests/HookSocketTests.swift
git commit -m "Add HookSocketClient and a socket round-trip test"
```

---

## Task 10: `casper hook` subcommand

**Files:**
- Create: `Sources/CasperCLI/HookCommand.swift`
- Test: `Tests/CasperCLITests/HookCommandTests.swift`

**Interfaces:**
- Consumes: `HookMessage`, `HookSocketClient` (CasperAgents); `ArgumentParser`.
- Produces:
  - `struct HookCommand: ParsableCommand`
    - `static let configuration = CommandConfiguration(commandName: "hook", ...)`
    - `static func makeMessage(stdin: Data, environment: [String: String]) -> HookMessage?`
    - `func run() throws`

`makeMessage` is the pure, testable core: it needs a valid `CASPER_WORKSPACE_ID`
(a UUID) and returns `nil` otherwise. `run()` reads stdin + environment, and if a
message and `CASPER_SOCKET` are present, sends it — swallowing any transport
error so a hook never blocks the agent.

- [ ] **Step 1: Write the failing tests**

`Tests/CasperCLITests/HookCommandTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCLI
import CasperAgents

final class HookCommandTests: XCTestCase {
    func testMakeMessageBuildsEnvelopeFromValidEnvironment() throws {
        let id = UUID()
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = try XCTUnwrap(HookCommand.makeMessage(
            stdin: stdin, environment: ["CASPER_WORKSPACE_ID": id.uuidString]))
        XCTAssertEqual(message.workspaceId, id)
        XCTAssertEqual(message.hookPayload, stdin)
    }

    func testMakeMessageReturnsNilWithoutWorkspaceId() {
        let message = HookCommand.makeMessage(
            stdin: Data("{}".utf8), environment: [:])
        XCTAssertNil(message)
    }

    func testMakeMessageReturnsNilForInvalidWorkspaceId() {
        let message = HookCommand.makeMessage(
            stdin: Data("{}".utf8),
            environment: ["CASPER_WORKSPACE_ID": "not-a-uuid"])
        XCTAssertNil(message)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookCommandTests`
Expected: FAIL — `cannot find 'HookCommand' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/CasperCLI/HookCommand.swift`:

```swift
import ArgumentParser
import CasperAgents
import Foundation

/// `casper hook` — invoked by Claude Code hooks. Reads the hook JSON on stdin,
/// wraps it with the surface's workspace id, and relays it to the app over the
/// `CASPER_SOCKET` Unix-domain socket. Never blocks the agent: missing env,
/// a missing socket, or a transport failure all exit 0.
public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Relay a Claude Code hook event to the Casper app.")

    public init() {}

    /// Build the wire envelope from raw stdin and the process environment, or
    /// `nil` when `CASPER_WORKSPACE_ID` is absent or not a UUID.
    public static func makeMessage(
        stdin: Data, environment: [String: String]
    ) -> HookMessage? {
        guard let raw = environment["CASPER_WORKSPACE_ID"],
              let workspaceId = UUID(uuidString: raw)
        else { return nil }
        return HookMessage(workspaceId: workspaceId, hookPayload: stdin)
    }

    public func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard let message = Self.makeMessage(stdin: stdin, environment: environment),
              let socketPath = environment["CASPER_SOCKET"]
        else { return }
        // Best-effort: a hook must never block or fail the agent.
        try? HookSocketClient.send(message, toSocketAt: socketPath)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HookCommandTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCLI/HookCommand.swift Tests/CasperCLITests/HookCommandTests.swift
git commit -m "Add the casper hook subcommand"
```

---

## Task 11: `casper hooks` command group + launch fork + executable

**Files:**
- Modify: `Sources/CasperAgents/ClaudeCodeAdapter.swift` (default hook command
  `"casper hook"` → `"casper hooks feed"`)
- Rename+modify: `Sources/CasperCLI/HookCommand.swift` →
  `Sources/CasperCLI/HooksFeedCommand.swift` (the relay, now `hooks feed`)
- Create: `Sources/CasperCLI/HooksCommand.swift` (the `hooks` group)
- Create: `Sources/CasperCLI/HooksSetupCommand.swift` (`casper hooks setup`)
- Create: `Sources/CasperCLI/CasperCommand.swift`
- Create: `Sources/CasperCLI/LaunchMode.swift`
- Modify: `Sources/casper/main.swift`
- Modify: `Sources/CasperCLI/CasperCLI.swift` (delete the placeholder body)
- Rename+modify test: `Tests/CasperCLITests/HookCommandTests.swift` →
  `Tests/CasperCLITests/HooksFeedCommandTests.swift`
- Modify test: `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift` (embedded
  command assertion → `"casper hooks feed"`)
- Create: `Tests/CasperCLITests/HooksSetupCommandTests.swift`
- Create: `Tests/CasperCLITests/HooksRoutingTests.swift`
- Create: `Tests/CasperCLITests/LaunchModeTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeAdapter` (Task 7), `HookMessage`/`HookSocketClient`
  (CasperAgents), `ArgumentParser`.
- Produces:
  - `struct HooksCommand: ParsableCommand` — the `hooks` group:
    `subcommands: [HooksFeedCommand.self, HooksSetupCommand.self]`, no `run()`.
  - `struct HooksFeedCommand: ParsableCommand` — `commandName: "feed"`.
    - `static func makeMessage(stdin: Data, environment: [String: String]) -> HookMessage?`
    - `func run() throws`
  - `struct HooksSetupCommand: ParsableCommand` — `commandName: "setup"`,
    `@Argument var worktree: String?` (defaults to cwd), `func run() throws`.
  - `struct CasperCommand: ParsableCommand` (root; subcommands `[HooksCommand]`).
  - `enum LaunchMode: Equatable { case gui; case cli; static func detect(arguments:) -> LaunchMode }`.

**Design note — `hooks` command family.** Casper's CLI
shape: a plural **`hooks`** group with `setup` (install) and `feed` (relay),
with `casper hooks setup` and `casper hooks feed`. Because Casper controls what the
generated `settings.local.json` invokes, the installed hooks call
**`casper hooks feed`** explicitly — so `feed` is a plain subcommand (no
default-subcommand trickery). `casper hooks feed` reads the hook JSON on stdin
(the event name is inside the payload; `HookEventParser` already extracts it), so
it needs no arguments. `casper hooks setup [<worktree>]` installs the hooks
**once** per worktree (defaults to cwd, idempotent, prints a one-line
confirmation — intended user-facing output, not test noise). Casper (Plan 5) runs
`hooks setup` once at workspace creation; it must **not** run on every terminal
open — only the surface environment (`CASPER_SOCKET`, `CASPER_WORKSPACE_ID`,
`CASPER_PORT…`) is injected per surface. (A `--agent` option and per-agent
`hooks <agent> install` are deferred: Casper v1 is Claude-only.)

`LaunchMode.detect` implements the argv fork: empty argv (just the program path)
means GUI; anything else is CLI. It lives in the library so it is unit-testable;
`main.swift` is a thin shim.

- [ ] **Step 1: Update the ClaudeCodeAdapter default and its test**

In `Sources/CasperAgents/ClaudeCodeAdapter.swift`, change the default parameter
value from `"casper hook"` to `"casper hooks feed"` in **both** `settingsJSON`
and `install` (the two `hookCommand: String = "casper hook"` defaults).

In `Tests/CasperAgentsTests/ClaudeCodeAdapterTests.swift`, update the embedded
command assertion in `testHookCommandIsEmbedded`:

```swift
        XCTAssertEqual(inner.first?["command"] as? String, "casper hooks feed")
```

- [ ] **Step 2: Write / update the failing tests**

Rename `Tests/CasperCLITests/HookCommandTests.swift` to
`Tests/CasperCLITests/HooksFeedCommandTests.swift` (`git mv`) and change its body
to target `HooksFeedCommand` (relay behavior unchanged):

```swift
import Foundation
import XCTest
@testable import CasperCLI
import CasperAgents

final class HooksFeedCommandTests: XCTestCase {
    func testMakeMessageBuildsEnvelopeFromValidEnvironment() throws {
        let id = UUID()
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = try XCTUnwrap(HooksFeedCommand.makeMessage(
            stdin: stdin, environment: ["CASPER_WORKSPACE_ID": id.uuidString]))
        XCTAssertEqual(message.workspaceId, id)
        XCTAssertEqual(message.hookPayload, stdin)
    }

    func testMakeMessageReturnsNilWithoutWorkspaceId() {
        let message = HooksFeedCommand.makeMessage(
            stdin: Data("{}".utf8), environment: [:])
        XCTAssertNil(message)
    }

    func testMakeMessageReturnsNilForInvalidWorkspaceId() {
        let message = HooksFeedCommand.makeMessage(
            stdin: Data("{}".utf8),
            environment: ["CASPER_WORKSPACE_ID": "not-a-uuid"])
        XCTAssertNil(message)
    }
}
```

`Tests/CasperCLITests/HooksSetupCommandTests.swift`:

```swift
import Foundation
import XCTest
import CasperAgents
import CasperCLI

final class HooksSetupCommandTests: XCTestCase {
    func testSetupWritesSettingsIntoGivenWorktree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-cli-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var command = try HooksSetupCommand.parse([dir.path])
        try command.run()

        let settings = ClaudeCodeAdapter.settingsPath(inWorktreeAt: dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings))
    }

    func testSetupDefaultsToCurrentDirectoryWhenNoArgument() throws {
        let command = try HooksSetupCommand.parse([])
        XCTAssertNil(command.worktree)
    }
}
```

`Tests/CasperCLITests/HooksRoutingTests.swift` (proves the group routes to the
right leaves — `casper hooks feed` reaches the relay, `casper hooks setup`
reaches setup):

```swift
import XCTest
import CasperCLI

final class HooksRoutingTests: XCTestCase {
    func testHooksFeedRoutesToFeed() throws {
        let command = try CasperCommand.parseAsRoot(["hooks", "feed"])
        XCTAssertTrue(command is HooksFeedCommand)
    }

    func testHooksSetupRoutesToSetup() throws {
        let command = try CasperCommand.parseAsRoot(["hooks", "setup", "/tmp/x"])
        XCTAssertTrue(command is HooksSetupCommand)
    }
}
```

`Tests/CasperCLITests/LaunchModeTests.swift`:

```swift
import XCTest
@testable import CasperCLI

final class LaunchModeTests: XCTestCase {
    func testNoArgumentsMeansGUI() {
        XCTAssertEqual(LaunchMode.detect(arguments: ["/path/to/casper"]), .gui)
    }

    func testEmptyArgumentsMeansGUI() {
        XCTAssertEqual(LaunchMode.detect(arguments: []), .gui)
    }

    func testASubcommandMeansCLI() {
        XCTAssertEqual(
            LaunchMode.detect(arguments: ["/path/to/casper", "hooks"]), .cli)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter HooksSetupCommandTests`
Expected: FAIL — `cannot find 'HooksSetupCommand' in scope`.

Run: `swift test --filter LaunchModeTests`
Expected: FAIL — `cannot find 'LaunchMode' in scope`.

- [ ] **Step 4: Write the implementations**

`Sources/CasperCLI/HooksFeedCommand.swift` (renamed from `HookCommand.swift`; the
relay logic is identical to Task 10, only the type name / commandName change):

```swift
import ArgumentParser
import CasperAgents
import Foundation

/// `casper hooks feed` — invoked by Claude Code hooks (the generated
/// `settings.local.json` calls this). Reads the hook JSON on stdin, wraps it
/// with the surface's workspace id, and relays it to the app over the
/// `CASPER_SOCKET` Unix-domain socket. Never blocks the agent: missing env,
/// a missing socket, or a transport failure all exit 0.
public struct HooksFeedCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "feed",
        abstract: "Relay a Claude Code hook event to the Casper app.")

    public init() {}

    /// Build the wire envelope from raw stdin and the process environment, or
    /// `nil` when `CASPER_WORKSPACE_ID` is absent or not a UUID.
    public static func makeMessage(
        stdin: Data, environment: [String: String]
    ) -> HookMessage? {
        guard let raw = environment["CASPER_WORKSPACE_ID"],
              let workspaceId = UUID(uuidString: raw)
        else { return nil }
        return HookMessage(workspaceId: workspaceId, hookPayload: stdin)
    }

    public func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard let message = Self.makeMessage(stdin: stdin, environment: environment),
              let socketPath = environment["CASPER_SOCKET"]
        else { return }
        // Best-effort: a hook must never block or fail the agent.
        try? HookSocketClient.send(message, toSocketAt: socketPath)
    }
}
```

`Sources/CasperCLI/HooksSetupCommand.swift`:

```swift
import ArgumentParser
import CasperAgents
import Foundation

/// `casper hooks setup [<worktree>]` — write Casper's Claude Code hooks into a
/// worktree's `.claude/settings.local.json`, ONCE. Casper runs this when a
/// workspace is created; a user may also run it manually. Idempotent
/// (overwrites the file); not meant to run on every terminal open — per-surface
/// environment injection handles runtime identity separately.
public struct HooksSetupCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install Casper's Claude Code hooks into a worktree.")

    @Argument(help: "Worktree directory (defaults to the current directory).")
    public var worktree: String?

    public init() {}

    public func run() throws {
        let path = worktree ?? FileManager.default.currentDirectoryPath
        try ClaudeCodeAdapter.install(intoWorktreeAt: path)
        print("Installed Casper hooks into "
            + ClaudeCodeAdapter.settingsPath(inWorktreeAt: path))
    }
}
```

`Sources/CasperCLI/HooksCommand.swift`:

```swift
import ArgumentParser

/// `casper hooks` — Claude Code hook integration, providing a `hooks`
/// command family: `casper hooks setup` installs the hooks into a worktree,
/// and `casper hooks feed` (invoked by those installed hooks) relays events.
public struct HooksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Set up and relay Casper's Claude Code hooks.",
        subcommands: [HooksFeedCommand.self, HooksSetupCommand.self])

    public init() {}
}
```

`Sources/CasperCLI/LaunchMode.swift`:

```swift
import Foundation

/// How the single binary was invoked. Empty argv (only the program path) means
/// the user double-clicked / launched the app → GUI; any argument means CLI.
public enum LaunchMode: Equatable {
    case gui
    case cli

    public static func detect(arguments: [String]) -> LaunchMode {
        arguments.count <= 1 ? .gui : .cli
    }
}
```

`Sources/CasperCLI/CasperCommand.swift`:

```swift
import ArgumentParser

/// The root `casper` command. v1 ships the `casper hooks` family (`setup` +
/// `feed`); `open` and `worktree` land in a later plan.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        subcommands: [HooksCommand.self])

    public init() {}
}
```

Delete the placeholder comment in `Sources/CasperCLI/CasperCLI.swift` (leave the
file empty or remove it; SwiftPM now has real sources in the target).

`Sources/casper/main.swift` (replace the whole file):

```swift
import CasperCLI
import Foundation

// Single-binary fork: empty argv launches the GUI (Plan 5); any subcommand runs
// the CLI. The GUI is not yet available, so GUI mode prints a notice for now.
switch LaunchMode.detect(arguments: CommandLine.arguments) {
case .gui:
    FileHandle.standardError.write(
        Data("Casper GUI is not available yet (arrives in Plan 5).\n".utf8))
case .cli:
    CasperCommand.main()
}
```

- [ ] **Step 5: Run tests, build, and manual checks**

Run: `swift test --filter CasperCLITests`
Expected: PASS — `HooksFeedCommandTests` (3), `HooksSetupCommandTests` (2),
`HooksRoutingTests` (2), `LaunchModeTests` (3).

Run: `swift test --filter ClaudeCodeAdapterTests`
Expected: PASS (6) with the updated `"casper hooks feed"` assertion.

Run: `swift build`
Expected: PASS (the `casper` executable links).

Run: `echo '{"hook_event_name":"Stop"}' | swift run casper hooks feed`
Expected: exits 0 with no output (no `CASPER_SOCKET`/`CASPER_WORKSPACE_ID` set,
so the relay is a silent no-op).

Run: `swift run casper hooks setup /tmp/casper-manual-check && cat /tmp/casper-manual-check/.claude/settings.local.json && rm -rf /tmp/casper-manual-check`
Expected: prints the confirmation, then the generated hooks JSON whose command is
`casper hooks feed`.

Run: `swift run casper hooks --help`
Expected: help lists the `feed` and `setup` subcommands.

Then run the full suite once:

Run: `swift test`
Expected: PASS — expect ~88 tests (81 prior + 7 net new; the 3 relay tests are
renamed, not added). Report the actual observed count.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests
git commit -m "Add casper hooks command family and the launch fork"
```

---

## Task 12: End-to-end integration + docs

**Files:**
- Create: `Tests/CasperCLITests/EndToEndHookTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: `ClaudeCodeAdapter`, `HookSocketServer`, `HookMessage`
  (CasperAgents); `HooksFeedCommand` (CasperCLI); `HookEventParser`,
  `AgentStateStore` (CasperCore).

Proves the whole pipe: build the surface environment with `ClaudeCodeAdapter`,
build a message with `HooksFeedCommand.makeMessage` from that environment, send it
through `HookSocketClient` to a live `HookSocketServer`, decode it with
`HookEventParser`, and drive an `AgentStateStore` — the spec's "end-to-end agent
adapter driven by a fake agent" (the fake agent here is the test emitting a hook
frame).

- [ ] **Step 1: Write the failing test**

`Tests/CasperCLITests/EndToEndHookTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCLI
import CasperAgents
import CasperCore

final class EndToEndHookTests: XCTestCase {
    func testStopHookDrivesAgentStateToDone() throws {
        let socketPath = "/tmp/casper-e2e-\(UUID().uuidString.prefix(8)).sock"

        let workspace = Workspace(
            name: "e2e", repoPath: "/repo", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0))
        let store = AgentStateStore(workspaces: [workspace])

        // Surface env, exactly as a terminal surface would receive it.
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: socketPath, workspaceId: workspace.id, portBase: 40000)

        let done = XCTestExpectation(description: "state reached .done")
        let server = HookSocketServer(socketPath: socketPath)
        server.onMessage = { message in
            guard let event = try? HookEventParser.parse(message.hookPayload)
            else { return }
            store.handle(event, workspaceId: message.workspaceId, focused: true)
            if store.workspace(id: workspace.id)?.agentState == .done {
                done.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }

        // The "fake agent": a Stop hook payload built through the CLI path.
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = try XCTUnwrap(
            HooksFeedCommand.makeMessage(stdin: stdin, environment: env))
        try HookSocketClient.send(message, toSocketAt: socketPath)

        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.workspace(id: workspace.id)?.agentState, .done)
    }
}
```

- [ ] **Step 2: Run test to verify it fails, then passes**

Run: `swift test --filter EndToEndHookTests`
Expected: PASS (all pieces already exist from Tasks 2–11; if it fails, the
failure localizes the integration gap).

- [ ] **Step 3: Run the full suite**

Run: `make test`
Expected: PASS — all prior tests (56 from Plans 1–2) plus the new CasperCore,
CasperAgents, and CasperCLI tests are green.

- [ ] **Step 4: Update the README**

In `README.md`, under the module/status section, mark **CasperAgents** and
**CasperCLI** as implemented and note the `casper hooks setup` /
`casper hooks feed` commands and the `CASPER_SOCKET` / `CASPER_WORKSPACE_ID` /
`CASPER_PORT` surface environment. Match the surrounding style; keep lines ≤ 80
columns.

- [ ] **Step 5: Commit**

```bash
git add Tests/CasperCLITests/EndToEndHookTests.swift README.md
git commit -m "Add end-to-end hook integration test and update the README"
```

---

## Self-Review Notes

- **Spec coverage:** single binary + argv fork (Task 11); `casper hook` (Task 10);
  Unix-domain socket server/client via Network.framework (Tasks 8–9); Claude Code
  `settings.local.json` + surface env, resolving §15 (Tasks 5–7); `AgentStateStore`
  state machine + todo aggregation (Task 2); `unknown`/`error` deferral honored
  (Task 3); end-to-end fake-agent integration (Task 12). Port env exposes the full
  reserved block (Task 6).
- **Out of scope (documented):** no global `casper` shim (dropped — `PATH`
  injection via `surfaceEnvironment` instead; Plan 5 passes the real bundle dir);
  real GUI + heartbeat timer wiring → Plan 5; `casper open`/`casper worktree` →
  later plan. The `HeartbeatMonitor` logic and `markUnknown`/`markError`
  transitions ship here so Plan 5 only wires a timer.
- **Type consistency:** `hookCommand:` default is `"casper hooks feed"` (updated
  from `"casper hook"` in Task 11) uniformly across `ClaudeCodeAdapter`;
  `HookMessage(workspaceId:hookPayload:)`, `HookSocketClient.send(_:
  toSocketAt:timeout:)`, `AgentStateStore.handle(_:workspaceId:focused:)` names
  match across their consumers.
- **Risk to verify during execution:** the Network.framework Unix-endpoint bind
  (`NWParameters(tls:tcp:)` + `requiredLocalEndpoint = .unix(path:)` +
  `allowLocalEndpointReuse`) is confirmed against Apple Developer Forums; if the
  listener emits benign debug warnings, that is expected and does not fail tests.
  AF_UNIX path length is limited (~104 chars) — tests use short `/tmp/...` paths.
