# Casper Core Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Status: ✅ COMPLETE — 2026-07-01.** All 7 tasks implemented, reviewed, and committed on `main`; every checkbox below is ticked. **30 XCTest tests pass** locally (Xcode 26.6 toolchain) and are wired for CI. Repo is **local-only — not pushed** to GitHub yet (CI ready but unrun).
>
> **Plan-1 commits:** `6f40c09` (scaffold) → `beb9a71` (test hardening); plus `d9014e1` (CI + gitignore).
>
> **Deviations from the plan as written (all applied, verified green):**
> - Added `import Foundation` to `ModelsTests` / `SessionStoreTests` / `HookEventParserTests` — recent SDKs no longer re-export Foundation via `import XCTest` (see Global Constraints).
> - Added 4 hardening tests from the final review (`.todoUpdate` with no in-progress item, unknown todo-status fallback, missing `tool_name`, double-`reserve`). Suite is now **30 tests**.
> - `AgentState.unknown` / `.error` are intentionally **not produced** by the pure reducer; emitting them (heartbeat timeout / broken socket) is deferred to **Plan 3 (CLI + Agents)** — documented in the design spec §7.
>
> **Next milestone:** Plan 2 — CasperGit (libgit2 wrapper + `WorktreeManager`). libgit2 1.9.4 is already installed via Homebrew.

**Goal:** Build `CasperCore`, the pure-Swift, fully unit-tested backbone of Casper: domain models, session persistence, port-block allocation, Claude Code hook-event parsing, and the agent-state reducer.

**Architecture:** A SwiftPM package `Casper` with one library target `CasperCore` and its test target `CasperCoreTests`. No UI, no libgit2, no libghostty — this layer is 100% deterministic and testable via `swift test`. Later plans (CasperGit, CLI+Agents, CasperGhostty, CasperUI) depend on the types produced here.

**Tech Stack:** Swift 6.3 (installed), SwiftPM, XCTest, Foundation. Zero external dependencies in this plan.

## Global Constraints

- **Platform:** macOS 14+, **arm64-only**. `Package.swift` declares `platforms: [.macOS(.v14)]`.
- **Swift tools version:** `6.0` (toolchain 6.3.3 present).
- **Zero external dependencies** in `CasperCore` (the 3 allowed externals — GhosttyKit, swift-argument-parser, libgit2 — belong to later plans).
- **Naming:** module `CasperCore`; env var for ports is `CASPER_PORT`; agent hooks recognized: `SessionStart`, `Stop`, `Notification`, `PostToolUse` (matcher `TodoWrite`).
- **Todo status raw values** match Claude Code exactly: `pending`, `in_progress`, `completed`.
- **Port policy:** block size 10; default range `40000…49990` inclusive of bases (base ≡ `rangeStart (mod 10)`).
- All public types that carry only value data are `Sendable` and `Codable` where they belong to `Session`.
- **Testing & CI:** tests use **XCTest**, run by **GitHub Actions CI on `macos-14`** (Xcode present) and **locally** (Xcode 26.6 now installed). Locally, select the Xcode toolchain — either globally with `sudo xcode-select -s /Applications/Xcode.app`, or per-command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test`. **Do not run `swift test` with the Command Line Tools' `swift` binary** — it half-loads XCTest (`XCTestCase` resolves but `XCTAssert*` don't) and mixing toolchains corrupts `.build` (run `rm -rf .build` if it happens). Every XCTest test file that uses Foundation types (`URL`, `Data`, `FileManager`, `UUID`, `JSONEncoder`) **must `import Foundation` explicitly** — recent SDKs no longer re-export it through `import XCTest`. CI workflow lives at `.github/workflows/ci.yml`.

## Prerequisites

- The executor initializes a git repository at the project root at the start of execution (`git init`), which the user authorizes at that point. All "Commit" steps assume the repo exists.

## File Structure

```
Package.swift
Sources/CasperCore/
  Models.swift          # AgentState, TodoStatus, Todo, Surface, LayoutNode, Workspace, Session
  Progress.swift        # Workspace.progress / currentTask computed helpers
  PortAllocator.swift   # PortAllocator + PortAllocationError
  SessionStore.swift    # SessionStore (Codable persistence)
  HookEvent.swift       # HookEvent, HookParseError, HookEventParser
  AgentState.swift      # AgentEffect, AgentStateReducer
Tests/CasperCoreTests/
  ModelsTests.swift
  ProgressTests.swift
  PortAllocatorTests.swift
  SessionStoreTests.swift
  HookEventParserTests.swift
  AgentStateReducerTests.swift
```

Each file has one responsibility. `Models.swift` holds the persisted data shapes; behavior lives in its own file so models stay declarative.

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/CasperCore/CasperCore.swift`
- Test: `Tests/CasperCoreTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable `CasperCore` module exposing `public let casperCoreVersion: String`.

This is a scaffolding task; setup is folded in and the smoke test guards that the package builds and tests run.

- [x] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CasperCore", targets: ["CasperCore"]),
    ],
    targets: [
        .target(name: "CasperCore"),
        .testTarget(name: "CasperCoreTests", dependencies: ["CasperCore"]),
    ]
)
```

- [x] **Step 2: Create the module source**

`Sources/CasperCore/CasperCore.swift`:

```swift
public let casperCoreVersion = "0.1.0"
```

- [x] **Step 3: Write the smoke test**

`Tests/CasperCoreTests/SmokeTests.swift`:

```swift
import XCTest
@testable import CasperCore

final class SmokeTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(casperCoreVersion.isEmpty)
    }
}
```

- [x] **Step 4: Build and run**

Run: `swift test --filter SmokeTests`
Expected: builds, `1 test passed`.

- [x] **Step 5: Commit**

```bash
git add Package.swift Sources/CasperCore/CasperCore.swift Tests/CasperCoreTests/SmokeTests.swift
git commit -m "chore: scaffold CasperCore SwiftPM package"
```

---

### Task 2: Domain models

**Files:**
- Create: `Sources/CasperCore/Models.swift`
- Test: `Tests/CasperCoreTests/ModelsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum AgentState: String, Codable, Sendable` — cases `idle, running, waiting, done, error, unknown`
  - `enum TodoStatus: String, Codable, Sendable` — `pending`, `inProgress` (raw `"in_progress"`), `completed`
  - `struct Todo` — `content: String`, `status: TodoStatus`
  - `struct Surface` — `id: UUID`, `kind: Surface.Kind` where `Kind = .terminal(cwd: String, command: String?) | .browser(url: URL) | .diff(againstHead: Bool)`
  - `indirect enum LayoutNode` — `.split(orientation: Orientation, children: [LayoutNode], ratios: [Double]) | .tabGroup(surfaces: [Surface], activeIndex: Int)`; `Orientation = .horizontal | .vertical`
  - `struct Workspace` — `id, name, repoPath, worktreePath, branch, agentState, todos, pendingNotification, portBase, layout`
  - `struct Session` — `workspaces: [Workspace]`

- [x] **Step 1: Write the failing round-trip test**

`Tests/CasperCoreTests/ModelsTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt", command: nil))
        let browser = Surface(kind: .browser(url: URL(string: "http://localhost:40000")!))
        let diff = Surface(kind: .diff(againstHead: true))
        let layout = LayoutNode.split(
            orientation: .horizontal,
            children: [
                .tabGroup(surfaces: [term, browser], activeIndex: 0),
                .tabGroup(surfaces: [diff], activeIndex: 0),
            ],
            ratios: [0.6, 0.4]
        )
        let ws = Workspace(
            name: "feat-x",
            repoPath: "/repo",
            worktreePath: "/repo/wt",
            branch: "feat-x",
            agentState: .running,
            todos: [Todo(content: "wire up", status: .inProgress)],
            pendingNotification: false,
            portBase: 40010,
            layout: layout
        )
        return Session(workspaces: [ws])
    }

    func testSessionCodableRoundTrip() throws {
        let original = sampleSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTodoStatusRawValuesMatchClaudeCode() {
        XCTAssertEqual(TodoStatus.pending.rawValue, "pending")
        XCTAssertEqual(TodoStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TodoStatus.completed.rawValue, "completed")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelsTests`
Expected: FAIL — `cannot find 'Session' in scope` (types not defined yet).

- [x] **Step 3: Implement the models**

`Sources/CasperCore/Models.swift`:

```swift
import Foundation

public enum AgentState: String, Codable, Sendable {
    case idle, running, waiting, done, error, unknown
}

public enum TodoStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct Todo: Codable, Equatable, Sendable {
    public var content: String
    public var status: TodoStatus
    public init(content: String, status: TodoStatus) {
        self.content = content
        self.status = status
    }
}

public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case terminal(cwd: String, command: String?)
        case browser(url: URL)
        case diff(againstHead: Bool)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case split(orientation: Orientation, children: [LayoutNode], ratios: [Double])
    case tabGroup(surfaces: [Surface], activeIndex: Int)

    public enum Orientation: String, Codable, Sendable {
        case horizontal, vertical
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var repoPath: String
    public var worktreePath: String
    public var branch: String
    public var agentState: AgentState
    public var todos: [Todo]
    public var pendingNotification: Bool
    public var portBase: Int
    public var layout: LayoutNode

    public init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        worktreePath: String,
        branch: String,
        agentState: AgentState = .idle,
        todos: [Todo] = [],
        pendingNotification: Bool = false,
        portBase: Int,
        layout: LayoutNode
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.agentState = agentState
        self.todos = todos
        self.pendingNotification = pendingNotification
        self.portBase = portBase
        self.layout = layout
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var workspaces: [Workspace]
    public init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelsTests`
Expected: PASS — `2 tests passed`.

- [x] **Step 5: Commit**

```bash
git add Sources/CasperCore/Models.swift Tests/CasperCoreTests/ModelsTests.swift
git commit -m "feat: add CasperCore domain models with Codable round-trip"
```

---

### Task 3: Progress helpers

**Files:**
- Create: `Sources/CasperCore/Progress.swift`
- Test: `Tests/CasperCoreTests/ProgressTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `Todo`, `TodoStatus` (Task 2).
- Produces: `Workspace.progress -> (completed: Int, total: Int)` and `Workspace.currentTask -> String?`.

- [x] **Step 1: Write the failing test**

`Tests/CasperCoreTests/ProgressTests.swift`:

```swift
import XCTest
@testable import CasperCore

final class ProgressTests: XCTestCase {
    private func workspace(todos: [Todo]) -> Workspace {
        Workspace(
            name: "w", repoPath: "/r", worktreePath: "/r/w", branch: "b",
            todos: todos, portBase: 40000,
            layout: .tabGroup(surfaces: [], activeIndex: 0)
        )
    }

    func testProgressCountsCompletedOverTotal() {
        let ws = workspace(todos: [
            Todo(content: "a", status: .completed),
            Todo(content: "b", status: .completed),
            Todo(content: "c", status: .inProgress),
            Todo(content: "d", status: .pending),
        ])
        XCTAssertEqual(ws.progress.completed, 2)
        XCTAssertEqual(ws.progress.total, 4)
    }

    func testCurrentTaskIsTheInProgressItem() {
        let ws = workspace(todos: [
            Todo(content: "a", status: .completed),
            Todo(content: "wiring", status: .inProgress),
        ])
        XCTAssertEqual(ws.currentTask, "wiring")
    }

    func testCurrentTaskNilWhenNoneInProgress() {
        let ws = workspace(todos: [Todo(content: "a", status: .completed)])
        XCTAssertNil(ws.currentTask)
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProgressTests`
Expected: FAIL — `value of type 'Workspace' has no member 'progress'`.

- [x] **Step 3: Implement the helpers**

`Sources/CasperCore/Progress.swift`:

```swift
import Foundation

public extension Workspace {
    var progress: (completed: Int, total: Int) {
        let completed = todos.filter { $0.status == .completed }.count
        return (completed, todos.count)
    }

    var currentTask: String? {
        todos.first { $0.status == .inProgress }?.content
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProgressTests`
Expected: PASS — `3 tests passed`.

- [x] **Step 5: Commit**

```bash
git add Sources/CasperCore/Progress.swift Tests/CasperCoreTests/ProgressTests.swift
git commit -m "feat: add workspace progress and current-task helpers"
```

---

### Task 4: Port allocator

**Files:**
- Create: `Sources/CasperCore/PortAllocator.swift`
- Test: `Tests/CasperCoreTests/PortAllocatorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct PortAllocationError: Error, Equatable { let reason: String }`
  - `struct PortAllocator: Equatable, Sendable` with:
    - `init(rangeStart: Int = 40000, rangeEnd: Int = 49990, blockSize: Int = 10)`
    - `var allocatedBases: Set<Int>` (read-only)
    - `mutating func allocate() throws -> Int` — returns the first free base
    - `@discardableResult mutating func reserve(_ base: Int) -> Bool` — mark a persisted base used
    - `mutating func release(_ base: Int)`

- [x] **Step 1: Write the failing tests**

`Tests/CasperCoreTests/PortAllocatorTests.swift`:

```swift
import XCTest
@testable import CasperCore

final class PortAllocatorTests: XCTestCase {
    func testAllocateReturnsSequentialBlocks() throws {
        var a = PortAllocator()
        XCTAssertEqual(try a.allocate(), 40000)
        XCTAssertEqual(try a.allocate(), 40010)
        XCTAssertEqual(try a.allocate(), 40020)
    }

    func testReserveSkipsRestoredBase() throws {
        var a = PortAllocator()
        XCTAssertTrue(a.reserve(40000))
        XCTAssertEqual(try a.allocate(), 40010)
    }

    func testReserveRejectsMisalignedOrOutOfRange() {
        var a = PortAllocator()
        XCTAssertFalse(a.reserve(40005)) // not a multiple of blockSize from start
        XCTAssertFalse(a.reserve(39990)) // below range
        XCTAssertFalse(a.reserve(50000)) // above range
    }

    func testReleaseAllowsReuse() throws {
        var a = PortAllocator()
        let first = try a.allocate()   // 40000
        _ = try a.allocate()           // 40010
        a.release(first)
        XCTAssertEqual(try a.allocate(), 40000) // reuses the freed lowest block
    }

    func testExhaustionThrows() {
        var a = PortAllocator(rangeStart: 40000, rangeEnd: 40010, blockSize: 10)
        XCTAssertNoThrow(try a.allocate()) // 40000
        XCTAssertNoThrow(try a.allocate()) // 40010
        XCTAssertThrowsError(try a.allocate()) { error in
            XCTAssertTrue(error is PortAllocationError)
        }
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter PortAllocatorTests`
Expected: FAIL — `cannot find 'PortAllocator' in scope`.

- [x] **Step 3: Implement the allocator**

`Sources/CasperCore/PortAllocator.swift`:

```swift
import Foundation

public struct PortAllocationError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct PortAllocator: Equatable, Sendable {
    public let rangeStart: Int
    public let rangeEnd: Int
    public let blockSize: Int
    private var used: Set<Int>

    public init(rangeStart: Int = 40000, rangeEnd: Int = 49990, blockSize: Int = 10) {
        precondition(blockSize > 0, "blockSize must be positive")
        precondition(rangeEnd >= rangeStart, "rangeEnd must be >= rangeStart")
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.blockSize = blockSize
        self.used = []
    }

    public var allocatedBases: Set<Int> { used }

    @discardableResult
    public mutating func reserve(_ base: Int) -> Bool {
        guard base >= rangeStart, base <= rangeEnd,
              (base - rangeStart) % blockSize == 0 else { return false }
        return used.insert(base).inserted
    }

    public mutating func release(_ base: Int) {
        used.remove(base)
    }

    public mutating func allocate() throws -> Int {
        var base = rangeStart
        while base <= rangeEnd {
            if !used.contains(base) {
                used.insert(base)
                return base
            }
            base += blockSize
        }
        throw PortAllocationError(
            reason: "no free \(blockSize)-port block in \(rangeStart)...\(rangeEnd)"
        )
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter PortAllocatorTests`
Expected: PASS — `5 tests passed`.

- [x] **Step 5: Commit**

```bash
git add Sources/CasperCore/PortAllocator.swift Tests/CasperCoreTests/PortAllocatorTests.swift
git commit -m "feat: add per-workspace port-block allocator"
```

---

### Task 5: Session store (persistence)

**Files:**
- Create: `Sources/CasperCore/SessionStore.swift`
- Test: `Tests/CasperCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `Session` (Task 2).
- Produces:
  - `final class SessionStore`
    - `init(fileURL: URL)`
    - `static func defaultURL(fileManager: FileManager = .default) throws -> URL` → `~/Library/Application Support/Casper/session.json`
    - `func load() throws -> Session` (returns empty `Session()` if the file is absent)
    - `func save(_ session: Session) throws` (atomic write, creates parent dir)

Note: debouncing of saves is an app-level concern (later plan); the store itself does a synchronous atomic write and stays trivially testable.

- [x] **Step 1: Write the failing tests**

`Tests/CasperCoreTests/SessionStoreTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class SessionStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
    }

    func testLoadMissingFileReturnsEmptySession() throws {
        let store = SessionStore(fileURL: tempFileURL())
        XCTAssertEqual(try store.load(), Session())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)

        let session = Session(workspaces: [
            Workspace(
                name: "w", repoPath: "/r", worktreePath: "/r/w", branch: "b",
                portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
            )
        ])
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
    }

    func testDefaultURLIsUnderApplicationSupportCasper() throws {
        let url = try SessionStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "session.json")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Casper")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionStoreTests`
Expected: FAIL — `cannot find 'SessionStore' in scope`.

- [x] **Step 3: Implement the store**

`Sources/CasperCore/SessionStore.swift`:

```swift
import Foundation

public final class SessionStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Casper", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.json", isDirectory: false)
    }

    public func load() throws -> Session {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Session()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(Session.self, from: data)
    }

    public func save(_ session: Session) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionStoreTests`
Expected: PASS — `3 tests passed`.

- [x] **Step 5: Commit**

```bash
git add Sources/CasperCore/SessionStore.swift Tests/CasperCoreTests/SessionStoreTests.swift
git commit -m "feat: add Codable SessionStore with atomic persistence"
```

---

### Task 6: Hook-event parser

**Files:**
- Create: `Sources/CasperCore/HookEvent.swift`
- Test: `Tests/CasperCoreTests/HookEventParserTests.swift`

**Interfaces:**
- Consumes: `Todo`, `TodoStatus` (Task 2).
- Produces:
  - `enum HookEvent: Equatable, Sendable` — `.sessionStart | .stop | .notification(message: String) | .todoUpdate(todos: [Todo])`
  - `enum HookParseError: Error, Equatable` — `.invalidJSON | .missingField(String) | .unsupportedEvent(String)`
  - `enum HookEventParser { static func parse(_ data: Data) throws -> HookEvent }`

> **Verify against installed Claude Code:** the JSON keys below (`hook_event_name`, `tool_name`, `tool_input.todos[].content/status`, `message`) reflect the documented hook payload. Before relying on them, confirm with a live hook dump from the installed Claude Code version (see plan §Open Questions in the spec). If a key differs, adjust the string literals here only.

- [x] **Step 1: Write the failing tests**

`Tests/CasperCoreTests/HookEventParserTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class HookEventParserTests: XCTestCase {
    private func parse(_ json: String) throws -> HookEvent {
        try HookEventParser.parse(Data(json.utf8))
    }

    func testSessionStart() throws {
        let event = try parse(#"{"hook_event_name":"SessionStart","source":"startup"}"#)
        XCTAssertEqual(event, .sessionStart)
    }

    func testStop() throws {
        let event = try parse(#"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(event, .stop)
    }

    func testNotificationCarriesMessage() throws {
        let event = try parse(#"{"hook_event_name":"Notification","message":"needs input"}"#)
        XCTAssertEqual(event, .notification(message: "needs input"))
    }

    func testPostToolUseTodoWriteParsesTodos() throws {
        let json = #"""
        {
          "hook_event_name": "PostToolUse",
          "tool_name": "TodoWrite",
          "tool_input": {
            "todos": [
              {"content": "design", "status": "completed", "activeForm": "designing"},
              {"content": "build", "status": "in_progress", "activeForm": "building"}
            ]
          }
        }
        """#
        let event = try parse(json)
        XCTAssertEqual(event, .todoUpdate(todos: [
            Todo(content: "design", status: .completed),
            Todo(content: "build", status: .inProgress),
        ]))
    }

    func testPostToolUseOtherToolIsUnsupported() {
        let json = #"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual(error as? HookParseError, .unsupportedEvent("PostToolUse:Bash"))
        }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try parse("not json")) { error in
            XCTAssertEqual(error as? HookParseError, .invalidJSON)
        }
    }

    func testMissingEventNameThrows() {
        XCTAssertThrowsError(try parse(#"{"foo":"bar"}"#)) { error in
            XCTAssertEqual(error as? HookParseError, .missingField("hook_event_name"))
        }
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookEventParserTests`
Expected: FAIL — `cannot find 'HookEventParser' in scope`.

- [x] **Step 3: Implement the parser**

`Sources/CasperCore/HookEvent.swift`:

```swift
import Foundation

public enum HookEvent: Equatable, Sendable {
    case sessionStart
    case stop
    case notification(message: String)
    case todoUpdate(todos: [Todo])
}

public enum HookParseError: Error, Equatable {
    case invalidJSON
    case missingField(String)
    case unsupportedEvent(String)
}

public enum HookEventParser {
    public static func parse(_ data: Data) throws -> HookEvent {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let obj = object as? [String: Any]
        else {
            throw HookParseError.invalidJSON
        }
        guard let name = obj["hook_event_name"] as? String else {
            throw HookParseError.missingField("hook_event_name")
        }

        switch name {
        case "SessionStart":
            return .sessionStart
        case "Stop":
            return .stop
        case "Notification":
            let message = obj["message"] as? String ?? ""
            return .notification(message: message)
        case "PostToolUse":
            let tool = obj["tool_name"] as? String ?? "?"
            guard tool == "TodoWrite" else {
                throw HookParseError.unsupportedEvent("PostToolUse:\(tool)")
            }
            let toolInput = obj["tool_input"] as? [String: Any] ?? [:]
            let rawTodos = toolInput["todos"] as? [[String: Any]] ?? []
            let todos = rawTodos.map { item -> Todo in
                let content = item["content"] as? String ?? ""
                let statusRaw = item["status"] as? String ?? "pending"
                return Todo(content: content, status: TodoStatus(rawValue: statusRaw) ?? .pending)
            }
            return .todoUpdate(todos: todos)
        default:
            throw HookParseError.unsupportedEvent(name)
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookEventParserTests`
Expected: PASS — `7 tests passed`.

- [x] **Step 5: Commit**

```bash
git add Sources/CasperCore/HookEvent.swift Tests/CasperCoreTests/HookEventParserTests.swift
git commit -m "feat: parse Claude Code hook events into HookEvent"
```

---

### Task 7: Agent-state reducer

**Files:**
- Create: `Sources/CasperCore/AgentState.swift`
- Test: `Tests/CasperCoreTests/AgentStateReducerTests.swift`

**Interfaces:**
- Consumes: `Workspace`, `AgentState`, `HookEvent`, `Todo` (Tasks 2, 6).
- Produces:
  - `enum AgentEffect: Equatable, Sendable` — `.notify(title: String, body: String)`
  - `enum AgentStateReducer { @discardableResult static func apply(_ event: HookEvent, to workspace: inout Workspace, focused: Bool) -> AgentEffect? }`

Reducer rules:
- `.sessionStart` → `agentState = .running`, clears `pendingNotification`; no effect.
- `.todoUpdate(todos)` → set `workspace.todos`; if any `.inProgress`, `agentState = .running`; no effect.
- `.notification(message)` → `agentState = .waiting`; if `!focused`, set `pendingNotification = true` and return `.notify(title: name, body: message)`.
- `.stop` → `agentState = .done`; if `!focused`, set `pendingNotification = true` and return `.notify(title: name, body: "Agent finished")`.

- [x] **Step 1: Write the failing tests**

`Tests/CasperCoreTests/AgentStateReducerTests.swift`:

```swift
import XCTest
@testable import CasperCore

final class AgentStateReducerTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        Workspace(
            name: "feat-x", repoPath: "/r", worktreePath: "/r/w", branch: "feat-x",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
        )
    }

    func testSessionStartSetsRunningAndClearsNotification() {
        var ws = makeWorkspace()
        ws.pendingNotification = true
        let effect = AgentStateReducer.apply(.sessionStart, to: &ws, focused: true)
        XCTAssertEqual(ws.agentState, .running)
        XCTAssertFalse(ws.pendingNotification)
        XCTAssertNil(effect)
    }

    func testTodoUpdateStoresTodosAndSetsRunningWhenInProgress() {
        var ws = makeWorkspace()
        let todos = [
            Todo(content: "a", status: .completed),
            Todo(content: "b", status: .inProgress),
        ]
        let effect = AgentStateReducer.apply(.todoUpdate(todos: todos), to: &ws, focused: true)
        XCTAssertEqual(ws.todos, todos)
        XCTAssertEqual(ws.agentState, .running)
        XCTAssertNil(effect)
    }

    func testNotificationWhenUnfocusedSetsWaitingAndNotifies() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.notification(message: "needs input"), to: &ws, focused: false)
        XCTAssertEqual(ws.agentState, .waiting)
        XCTAssertTrue(ws.pendingNotification)
        XCTAssertEqual(effect, .notify(title: "feat-x", body: "needs input"))
    }

    func testNotificationWhenFocusedDoesNotNotify() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.notification(message: "x"), to: &ws, focused: true)
        XCTAssertEqual(ws.agentState, .waiting)
        XCTAssertFalse(ws.pendingNotification)
        XCTAssertNil(effect)
    }

    func testStopWhenUnfocusedSetsDoneAndNotifies() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.stop, to: &ws, focused: false)
        XCTAssertEqual(ws.agentState, .done)
        XCTAssertTrue(ws.pendingNotification)
        XCTAssertEqual(effect, .notify(title: "feat-x", body: "Agent finished"))
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentStateReducerTests`
Expected: FAIL — `cannot find 'AgentStateReducer' in scope`.

- [x] **Step 3: Implement the reducer**

`Sources/CasperCore/AgentState.swift`:

```swift
import Foundation

public enum AgentEffect: Equatable, Sendable {
    case notify(title: String, body: String)
}

public enum AgentStateReducer {
    @discardableResult
    public static func apply(
        _ event: HookEvent,
        to workspace: inout Workspace,
        focused: Bool
    ) -> AgentEffect? {
        switch event {
        case .sessionStart:
            workspace.agentState = .running
            workspace.pendingNotification = false
            return nil

        case .todoUpdate(let todos):
            workspace.todos = todos
            if todos.contains(where: { $0.status == .inProgress }) {
                workspace.agentState = .running
            }
            return nil

        case .notification(let message):
            workspace.agentState = .waiting
            guard !focused else { return nil }
            workspace.pendingNotification = true
            return .notify(title: workspace.name, body: message)

        case .stop:
            workspace.agentState = .done
            guard !focused else { return nil }
            workspace.pendingNotification = true
            return .notify(title: workspace.name, body: "Agent finished")
        }
    }
}
```

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter AgentStateReducerTests`
Expected: PASS — `5 tests passed`.

- [x] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — all tests across the 6 suites green.

- [x] **Step 6: Commit**

```bash
git add Sources/CasperCore/AgentState.swift Tests/CasperCoreTests/AgentStateReducerTests.swift
git commit -m "feat: add agent-state reducer driving state and notifications"
```

---

## Self-Review

**Spec coverage (against `2026-07-01-casper-design.md`):**
- §5 Data Model → Task 2 (all types, Codable) + Task 3 (progress). ✓
- §7 Agent state & progress → Task 6 (hook parsing incl. `PostToolUse:TodoWrite`) + Task 7 (reducer, notifications). ✓
- §9 Port Reservation → Task 4 (`PortAllocator`, 10-block, reuse, exhaustion). ✓
- §10 Persistence → Task 5 (`SessionStore`, atomic, empty-on-missing, `portBase` persisted via `Session` round-trip in Tasks 2/5). ✓
- §13 Testing (unit: state machine, todo aggregation, hook parsing, SessionStore round-trip, PortAllocator) → all covered. ✓
- Out of scope here (later plans): `WorktreeManager`/libgit2 (Plan 2), CLI/socket/`casper hook`/settings.json (Plan 3), GhosttyRuntime (Plan 4), UI (Plan 5). Intentional.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. The one advisory note (verify Claude Code hook keys) is a runtime-verification caveat, not a missing implementation. ✓

**Type consistency:** `TodoStatus.inProgress` (raw `"in_progress"`) used identically in Tasks 2, 3, 6, 7. `AgentEffect.notify(title:body:)` defined and asserted with matching labels. `PortAllocator.allocate/reserve/release/allocatedBases` signatures match tests. `HookEvent` cases match parser output and reducer input. `SessionStore.load/save/defaultURL` match tests. ✓

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-01-casper-core-foundations.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
