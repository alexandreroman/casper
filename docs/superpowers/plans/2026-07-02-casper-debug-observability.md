# Casper Debug & Observability Channel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give an agent (and the developer) a compile-time-gated channel to observe and drive the running Casper GUI — read structured logs, dump state, read the terminal's live text, inject input, and screenshot.

**Architecture:** Three layers. (1) A `CasperLog` `os.Logger` facade in CasperCore. (2) A request/response Unix-socket channel: `Codable` protocol types + transport in CasperCore (reusing the `Network.framework` half-close pattern of `HookSocket`), a `DebugServer` dispatcher wired into `GhosttyDemo` in CasperGhostty, and a `casper debug` client subcommand in CasperCLI. (3) A `debug-casper` project skill documenting the runbook. Everything except the logging floor and the protocol/transport unit tests is gated by `#if DEBUG`.

**Tech Stack:** Swift 6 / SwiftPM, `os.Logger`, `Network.framework`, GhosttyKit (`ghostty_surface_read_text`/`ghostty_surface_size`), AppKit + CoreGraphics (`CGWindowListCreateImage`), swift-argument-parser, XCTest.

## Global Constraints

- Target **macOS 14+, arm64-only**, Swift 6 (`swift-tools-version: 6.0`).
- **No new external dependencies.** Only `Network.framework`, `CoreGraphics`, `AppKit`, `os`, `Foundation`, and existing GhosttyKit.
- **Debug channel is `#if DEBUG` only** — the socket server, `DebugServer`, `DebugSurfaceProvider` conformance, and the `casper debug` subcommand must be physically absent from `make release` (`swift build -c release`). No runtime flag may enable it in a release build.
- **Logging floor:** `.error`/`.fault` are always compiled in; `.debug`/`.info` are wrapped in `#if DEBUG`.
- `CASPER_DEBUG_SOCKET` selects only the socket **path**, never whether the channel exists. Default path `/tmp/casper-debug.sock` (short, well under the AF_UNIX 104-char limit).
- All generated text (code, docs, UI, log messages) in **English, present tense**.
- Code ≤ 120 columns; Markdown ≤ 80 columns, fenced blocks with a language tag.
- XCTest needs the full Xcode toolchain; XCTest files using Foundation types must `import Foundation`.
- Swift 6 concurrency: socket server classes are `@unchecked Sendable` with all I/O on a single serial queue; surface-touching work is `@MainActor` (see the existing `HookSocket` and `swift6-network-concurrency` conventions).

---

## File Structure

- `Sources/CasperCore/CasperLog.swift` — **Create.** `os.Logger` facade.
- `Sources/CasperCore/DebugProtocol.swift` — **Create.** `DebugCommand`, `DebugResponse`, `DebugState`.
- `Sources/CasperCore/DebugSocket.swift` — **Create.** `DebugSocketServer`, `DebugSocketClient`, default-path helper.
- `Sources/CasperGhostty/GhosttySurface.swift` — **Modify.** Add `readText`/`size` accessors.
- `Sources/CasperGhostty/GhosttySurfaceView.swift` — **Modify.** Swap `NSLog`→`CasperLog`; add `#if DEBUG` debug accessors.
- `Sources/CasperGhostty/DebugServer.swift` — **Create.** `#if DEBUG` provider protocol + dispatcher.
- `Sources/CasperGhostty/GhosttyDemo.swift` — **Modify.** Swap `NSLog`→`CasperLog`; start `DebugServer` and conform to the provider under `#if DEBUG`.
- `Sources/CasperCLI/DebugCLICommand.swift` — **Create.** `#if DEBUG` `casper debug` client subcommand.
- `Sources/CasperCLI/CasperCommand.swift` — **Modify.** Register `debug` subcommand under `#if DEBUG`.
- `Package.swift` — **Modify.** Add `CasperCore` as a dependency of `CasperGhostty`.
- `Tests/CasperCoreTests/DebugProtocolTests.swift` — **Create.**
- `Tests/CasperCoreTests/DebugSocketTests.swift` — **Create.**
- `.claude/skills/debug-casper/SKILL.md` — **Create.** Runbook.

---

## Task 1: `CasperLog` facade + wire CasperGhostty→CasperCore

**Files:**
- Create: `Sources/CasperCore/CasperLog.swift`
- Modify: `Package.swift` (add `CasperCore` dep to the `CasperGhostty` target)
- Modify: `Sources/CasperGhostty/GhosttyDemo.swift:54`, `Sources/CasperGhostty/GhosttySurfaceView.swift:41`
- Test: `Tests/CasperCoreTests/CasperLogTests.swift`

**Interfaces:**
- Produces: `enum CasperLog` with static `Logger` properties `app`, `ghostty`, `hooks`, `debug`, and `static let subsystem = "com.github.alexandreroman.casper"`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CasperCoreTests/CasperLogTests.swift
import XCTest
@testable import CasperCore

final class CasperLogTests: XCTestCase {
    func testSubsystemIsStable() {
        // The debug-casper skill's `log` predicate depends on this exact value.
        XCTAssertEqual(CasperLog.subsystem, "com.github.alexandreroman.casper")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CasperCoreTests.CasperLogTests`
Expected: FAIL — `CasperLog` is undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CasperCore/CasperLog.swift
import os

/// Central `os.Logger` facade. The subsystem is the stable key the `debug-casper`
/// skill filters on (`log show --predicate 'subsystem == "..."'`).
///
/// Gating discipline: `.error`/`.fault` calls stay compiled into release builds
/// for field crash diagnosis; verbose `.debug`/`.info` call sites are wrapped in
/// `#if DEBUG` at the call site.
public enum CasperLog {
    public static let subsystem = "com.github.alexandreroman.casper"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ghostty = Logger(subsystem: subsystem, category: "ghostty")
    public static let hooks = Logger(subsystem: subsystem, category: "hooks")
    public static let debug = Logger(subsystem: subsystem, category: "debug")
}
```

- [ ] **Step 4: Add `CasperCore` as a dependency of `CasperGhostty`**

In `Package.swift`, change the `CasperGhostty` target's `dependencies` from:

```swift
        .target(
            name: "CasperGhostty",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
```

to:

```swift
        .target(
            name: "CasperGhostty",
            dependencies: [
                "CasperCore",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
```

- [ ] **Step 5: Replace the two `NSLog` call sites**

In `Sources/CasperGhostty/GhosttySurfaceView.swift`, add `import CasperCore` at the top and change line 41 from:

```swift
            NSLog("Casper: surface creation failed: \(error)")
```

to (error path — always compiled in):

```swift
            CasperLog.ghostty.error("surface creation failed: \(String(describing: error))")
```

In `Sources/CasperGhostty/GhosttyDemo.swift`, add `import CasperCore` and change line 54 from:

```swift
            NSLog("Casper demo failed: \(error)")
```

to:

```swift
            CasperLog.ghostty.error("demo failed: \(String(describing: error))")
```

- [ ] **Step 6: Run the test and build to verify they pass**

Run: `swift test --filter CasperCoreTests.CasperLogTests && swift build`
Expected: test PASS; build succeeds with CasperGhostty now importing CasperCore.

- [ ] **Step 7: Commit**

```bash
git add Sources/CasperCore/CasperLog.swift Package.swift \
  Sources/CasperGhostty/GhosttyDemo.swift Sources/CasperGhostty/GhosttySurfaceView.swift \
  Tests/CasperCoreTests/CasperLogTests.swift
git commit -m "Add CasperLog os.Logger facade and route Ghostty logging through it"
```

---

## Task 2: Debug protocol types

**Files:**
- Create: `Sources/CasperCore/DebugProtocol.swift`
- Test: `Tests/CasperCoreTests/DebugProtocolTests.swift`

**Interfaces:**
- Produces:
  - `struct DebugCommand: Codable, Equatable, Sendable` with `enum Verb: String { dumpState, readText, sendText, screenshot }`, and optional payload fields `text: String?`, `enter: Bool?`, `scrollback: Bool?`, `path: String?`.
  - `struct DebugState: Codable, Equatable, Sendable` with `struct Surface { title: String; workingDirectory: String?; columns: Int; rows: Int; focused: Bool }` and `surfaces: [Surface]`.
  - `struct DebugResponse: Codable, Equatable, Sendable` with `ok: Bool`, `text: String?`, `state: DebugState?`, `error: String?`, plus `static func failure(_:)` and `static func success(...)` conveniences.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CasperCoreTests/DebugProtocolTests.swift
import Foundation
import XCTest
@testable import CasperCore

final class DebugProtocolTests: XCTestCase {
    func testCommandRoundTrip() throws {
        let command = DebugCommand(verb: .sendText, text: "ls", enter: true)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DebugCommand.self, from: data)
        XCTAssertEqual(decoded, command)
    }

    func testResponseWithStateRoundTrip() throws {
        let state = DebugState(surfaces: [
            .init(title: "casper", workingDirectory: "/tmp", columns: 80, rows: 24, focused: true),
        ])
        let response = DebugResponse.success(state: state)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(DebugResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.state?.surfaces.first?.columns, 80)
    }

    func testFailureHelper() {
        let response = DebugResponse.failure("no surface")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no surface")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CasperCoreTests.DebugProtocolTests`
Expected: FAIL — `DebugCommand`/`DebugState`/`DebugResponse` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CasperCore/DebugProtocol.swift
import Foundation

/// A single debug command sent from `casper debug` to the running GUI.
/// One flat struct (rather than an enum with associated values) keeps the JSON
/// wire form trivial and stable across the CLI/app boundary.
public struct DebugCommand: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable {
        case dumpState
        case readText
        case sendText
        case screenshot
    }

    public var verb: Verb
    public var text: String?        // sendText payload
    public var enter: Bool?         // sendText: append a trailing newline
    public var scrollback: Bool?    // readText: full screen vs. viewport
    public var path: String?        // screenshot: output file path

    public init(
        verb: Verb, text: String? = nil, enter: Bool? = nil,
        scrollback: Bool? = nil, path: String? = nil
    ) {
        self.verb = verb
        self.text = text
        self.enter = enter
        self.scrollback = scrollback
        self.path = path
    }
}

/// Snapshot of the app's observable UI state, returned by `dumpState`.
public struct DebugState: Codable, Equatable, Sendable {
    public struct Surface: Codable, Equatable, Sendable {
        public var title: String
        public var workingDirectory: String?
        public var columns: Int
        public var rows: Int
        public var focused: Bool

        public init(
            title: String, workingDirectory: String?, columns: Int, rows: Int, focused: Bool
        ) {
            self.title = title
            self.workingDirectory = workingDirectory
            self.columns = columns
            self.rows = rows
            self.focused = focused
        }
    }

    public var surfaces: [Surface]

    public init(surfaces: [Surface]) { self.surfaces = surfaces }
}

/// The reply to a `DebugCommand`. `text` carries read-text output or a
/// screenshot path; `state` carries a `dumpState` snapshot; `error` is set when
/// `ok` is false.
public struct DebugResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    public var state: DebugState?
    public var error: String?

    public init(ok: Bool, text: String? = nil, state: DebugState? = nil, error: String? = nil) {
        self.ok = ok
        self.text = text
        self.state = state
        self.error = error
    }

    public static func success(text: String? = nil, state: DebugState? = nil) -> DebugResponse {
        DebugResponse(ok: true, text: text, state: state)
    }

    public static func failure(_ message: String) -> DebugResponse {
        DebugResponse(ok: false, error: message)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CasperCoreTests.DebugProtocolTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/DebugProtocol.swift Tests/CasperCoreTests/DebugProtocolTests.swift
git commit -m "Add DebugCommand/DebugResponse/DebugState debug protocol types"
```

---

## Task 3: Debug socket transport (request/response)

**Files:**
- Create: `Sources/CasperCore/DebugSocket.swift`
- Test: `Tests/CasperCoreTests/DebugSocketTests.swift`

**Interfaces:**
- Consumes: `DebugCommand`, `DebugResponse` (Task 2).
- Produces:
  - `final class DebugSocketServer: @unchecked Sendable` — `init(socketPath:)`, `var onCommand: ((DebugCommand, @escaping @Sendable (DebugResponse) -> Void) -> Void)?`, `var onFailure: ((Error) -> Void)?`, `func start() throws`, `func stop()`.
  - `enum DebugSocketClient` — `static func send(_ command: DebugCommand, toSocketAt path: String, timeout: TimeInterval = 5) throws -> DebugResponse`.
  - `struct DebugSocketError: Error, Equatable { let reason: String }`.
  - `enum DebugSocketPath { static var `default`: String }` — `CASPER_DEBUG_SOCKET` env or `/tmp/casper-debug.sock`.

**Framing:** the client `send`s the request with `isComplete: true` (half-closes its write side), then reads to EOF for the response. The server reads the request to EOF, invokes `onCommand`, `send`s the response with `isComplete: true`, then cancels. This mirrors the existing `HookSocket` half-close discipline, extended to a reply.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/CasperCoreTests/DebugSocketTests.swift
import Foundation
import XCTest
@testable import CasperCore

final class DebugSocketTests: XCTestCase {
    private func tempSocketPath() -> String {
        "/tmp/casper-dbg-test-\(UUID().uuidString.prefix(8)).sock"
    }

    func testRoundTripReturnsServerResponse() throws {
        let path = tempSocketPath()
        let server = DebugSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .readText)
            reply(.success(text: "viewport contents"))
        }
        try server.start()
        defer { server.stop() }

        let response = try DebugSocketClient.send(
            DebugCommand(verb: .readText, scrollback: false), toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "viewport contents")
    }

    func testClientThrowsWhenSocketMissing() {
        XCTAssertThrowsError(
            try DebugSocketClient.send(
                DebugCommand(verb: .dumpState),
                toSocketAt: "/tmp/casper-dbg-none-\(UUID().uuidString).sock",
                timeout: 1))
    }

    func testDefaultPathHonorsEnvOverride() {
        // Default when unset.
        XCTAssertEqual(DebugSocketPath.default, "/tmp/casper-debug.sock")
    }
}
```

Note: `testDefaultPathHonorsEnvOverride` asserts the default; it assumes
`CASPER_DEBUG_SOCKET` is unset in the test environment (it is, in CI and locally).

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CasperCoreTests.DebugSocketTests`
Expected: FAIL — `DebugSocketServer`/`DebugSocketClient`/`DebugSocketPath` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/CasperCore/DebugSocket.swift
import Foundation
import Network
import os

/// Default socket path for the debug channel. The env var only selects the
/// path; whether the channel exists at all is decided at compile time (`#if
/// DEBUG`) by the app and CLI that use this transport.
public enum DebugSocketPath {
    public static var `default`: String {
        ProcessInfo.processInfo.environment["CASPER_DEBUG_SOCKET"] ?? "/tmp/casper-debug.sock"
    }
}

/// A transport failure on the debug channel.
public struct DebugSocketError: Error, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

/// Listens on a Unix-domain socket for one `DebugCommand` per connection and
/// writes back one `DebugResponse`. Request framing is half-close (read to EOF),
/// matching `HookSocketServer`; the reply is sent with `isComplete: true`.
///
/// `@unchecked Sendable`: wraps `Network.framework` whose handlers are
/// `@Sendable`; all connection I/O runs on the single serial `queue`, and
/// callbacks are configured before `start()`.
public final class DebugSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "casper.debug-socket.server")
    private var listener: NWListener?

    /// Invoked on the server queue with each decoded command and a `reply`
    /// callback. The handler MUST call `reply` exactly once (it may hop threads
    /// first). `reply` writes the response and closes the connection.
    public var onCommand: ((DebugCommand, @escaping @Sendable (DebugResponse) -> Void) -> Void)?
    /// Invoked on the server queue if the listener fails.
    public var onFailure: ((Error) -> Void)?

    public init(socketPath: String) { self.socketPath = socketPath }

    public func start() throws {
        unlink(socketPath)  // remove any stale socket file before binding

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        let listener = try NWListener(using: params)

        let bound = DispatchSemaphore(value: 0)
        let bindError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                bound.signal()
            case .failed(let error):
                bindError.withLock { $0 = error }
                self?.onFailure?(error)
                bound.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.receive(on: connection)
        }
        self.listener = listener
        listener.start(queue: queue)

        bound.wait()
        if let error = bindError.withLock({ $0 }) {
            self.listener = nil
            throw error
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    private func receive(on connection: NWConnection) {
        connection.start(queue: queue)
        receiveChunk(on: connection, accumulated: Data())
    }

    private func receiveChunk(on connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            var buffer = accumulated
            if let data { buffer.append(data) }
            if isComplete || error != nil {
                self?.dispatch(buffer, on: connection)
            } else {
                self?.receiveChunk(on: connection, accumulated: buffer)
            }
        }
    }

    private func dispatch(_ buffer: Data, on connection: NWConnection) {
        guard let command = try? JSONDecoder().decode(DebugCommand.self, from: buffer) else {
            reply(.failure("undecodable command"), on: connection)
            return
        }
        guard let onCommand else {
            reply(.failure("no handler"), on: connection)
            return
        }
        onCommand(command) { [weak self] response in
            self?.reply(response, on: connection)
        }
    }

    private func reply(_ response: DebugResponse, on connection: NWConnection) {
        let data = (try? JSONEncoder().encode(response)) ?? Data()
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Sends one `DebugCommand` to the app's debug socket and returns the decoded
/// `DebugResponse`. Synchronous by design: `casper debug` is short-lived.
public enum DebugSocketClient {
    public static func send(
        _ command: DebugCommand, toSocketAt socketPath: String, timeout: TimeInterval = 5
    ) throws -> DebugResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DebugSocketError(reason: "no socket at \(socketPath) (is the GUI running?)")
        }

        let data = try JSONEncoder().encode(command)

        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: params)
        let queue = DispatchQueue(label: "casper.debug-socket.client")
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<DebugResponse, Error>?>(initialState: nil)

        func finish(_ value: Result<DebugResponse, Error>) {
            result.withLock { if $0 == nil { $0 = value } }
            done.signal()
        }

        // Accumulate the reply until the server half-closes (EOF).
        func receiveResponse(_ accumulated: Data) {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { chunk, _, isComplete, error in
                var buffer = accumulated
                if let chunk { buffer.append(chunk) }
                if let error {
                    finish(.failure(DebugSocketError(reason: "\(error)")))
                    connection.cancel()
                    return
                }
                if isComplete {
                    if let response = try? JSONDecoder().decode(DebugResponse.self, from: buffer) {
                        finish(.success(response))
                    } else {
                        finish(.failure(DebugSocketError(reason: "undecodable response")))
                    }
                    connection.cancel()
                } else {
                    receiveResponse(buffer)
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data, isComplete: true, completion: .contentProcessed { error in
                    if let error {
                        finish(.failure(DebugSocketError(reason: "\(error)")))
                        connection.cancel()
                    }
                })
                receiveResponse(Data())
            case .failed(let error):
                finish(.failure(DebugSocketError(reason: "\(error)")))
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)

        if done.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw DebugSocketError(reason: "timed out talking to \(socketPath)")
        }
        switch result.withLock({ $0 }) {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw DebugSocketError(reason: "no response from \(socketPath)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CasperCoreTests.DebugSocketTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/DebugSocket.swift Tests/CasperCoreTests/DebugSocketTests.swift
git commit -m "Add request/response debug socket transport (server + client)"
```

---

## Task 4: `GhosttySurface` text/size accessors

**Files:**
- Modify: `Sources/CasperGhostty/GhosttySurface.swift` (append two methods before the closing brace)

**Interfaces:**
- Produces on `GhosttySurface`:
  - `func readText(scrollback: Bool) -> String?` — viewport (or full screen) text via `ghostty_surface_read_text`.
  - `func surfaceSize() -> (columns: Int, rows: Int)` — via `ghostty_surface_size`.

No unit test: these call into a live libghostty surface and are exercised by the
Task 8 manual GUI harness. Verify by building.

- [ ] **Step 1: Add the accessors**

Insert before the final closing `}` of `GhosttySurface`:

```swift
    /// Read the terminal's text: the visible viewport, or the full screen
    /// (including scrollback) when `scrollback` is true. Returns nil if
    /// libghostty declines to produce a selection.
    public func readText(scrollback: Bool) -> String? {
        let tag = scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        guard let bytes = out.text else { return "" }
        return String(decoding: Data(bytes: bytes, count: Int(out.text_len)), as: UTF8.self)
    }

    /// Current terminal grid dimensions.
    public func surfaceSize() -> (columns: Int, rows: Int) {
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }
```

Add `import Foundation` at the top of the file (for `Data`), after `import GhosttyKit`.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/CasperGhostty/GhosttySurface.swift
git commit -m "Add readText and surfaceSize accessors to GhosttySurface"
```

---

## Task 5: `DebugSurfaceProvider` + `DebugServer` dispatcher

**Files:**
- Create: `Sources/CasperGhostty/DebugServer.swift`
- Modify: `Sources/CasperGhostty/GhosttySurfaceView.swift` (add `#if DEBUG` debug accessors)

**Interfaces:**
- Consumes: `DebugCommand`, `DebugResponse`, `DebugState`, `DebugSocketServer` (CasperCore); `GhosttySurface.readText`/`surfaceSize` (Task 4).
- Produces (all under `#if DEBUG`):
  - `struct DebugSurfaceHandle` — value type describing one surface: `title: String`, `workingDirectory: String?`, `focused: Bool`, `readText: (Bool) -> String?`, `sendText: (String) -> Void`, `columnsRows: () -> (Int, Int)`, `window: NSWindow?`.
  - `@MainActor protocol DebugSurfaceProvider: AnyObject { func debugSurfaces() -> [DebugSurfaceHandle] }`.
  - `@MainActor final class DebugServer` — `init(socketPath:provider:)`, `func start() throws`, `func stop()`.
  - On `GhosttySurfaceView`: `#if DEBUG func debugReadText(scrollback: Bool) -> String?`, `func debugSendText(_ text: String)`, `func debugColumnsRows() -> (Int, Int)`, `var debugHasSurface: Bool`.

No unit test: `DebugServer` drives live AppKit/libghostty on the main thread and
is verified by the Task 8 GUI harness. Verify by building.

- [ ] **Step 1: Expose `#if DEBUG` accessors on `GhosttySurfaceView`**

Add to `GhosttySurfaceView` (its `surface` property is private, so these bridge to it). Insert after the `viewDidMoveToWindow()` method:

```swift
    // MARK: Debug accessors (compiled only into debug builds)

    #if DEBUG
    var debugHasSurface: Bool { surface != nil }

    func debugReadText(scrollback: Bool) -> String? {
        surface?.readText(scrollback: scrollback)
    }

    func debugSendText(_ text: String) {
        surface?.sendText(text)
    }

    func debugColumnsRows() -> (Int, Int) {
        surface?.surfaceSize() ?? (0, 0)
    }
    #endif
```

- [ ] **Step 2: Write `DebugServer.swift`**

```swift
// Sources/CasperGhostty/DebugServer.swift
#if DEBUG
import AppKit
import CasperCore
import CoreGraphics

/// A snapshot description of one live surface, decoupling `DebugServer` from the
/// concrete AppKit view. The provider builds these on the main thread.
@MainActor
public struct DebugSurfaceHandle {
    public let title: String
    public let workingDirectory: String?
    public let focused: Bool
    public let readText: (_ scrollback: Bool) -> String?
    public let sendText: (_ text: String) -> Void
    public let columnsRows: () -> (Int, Int)
    public let window: NSWindow?

    public init(
        title: String, workingDirectory: String?, focused: Bool,
        readText: @escaping (_ scrollback: Bool) -> String?,
        sendText: @escaping (_ text: String) -> Void,
        columnsRows: @escaping () -> (Int, Int),
        window: NSWindow?
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.focused = focused
        self.readText = readText
        self.sendText = sendText
        self.columnsRows = columnsRows
        self.window = window
    }
}

/// Supplies the current set of surfaces to the debug server. `GhosttyDemo`
/// conforms today; the Plan 5 app conforms later.
@MainActor
public protocol DebugSurfaceProvider: AnyObject {
    func debugSurfaces() -> [DebugSurfaceHandle]
}

/// Binds the debug socket and dispatches `DebugCommand`s against the provider's
/// surfaces on the main thread. Debug builds only.
@MainActor
public final class DebugServer {
    private let server: DebugSocketServer
    private weak var provider: (any DebugSurfaceProvider)?

    public init(socketPath: String, provider: any DebugSurfaceProvider) {
        self.provider = provider
        self.server = DebugSocketServer(socketPath: socketPath)
        self.server.onCommand = { [weak self] command, reply in
            // onCommand runs on the socket queue; surface work is main-thread only.
            Task { @MainActor in
                let response = self?.handle(command) ?? .failure("server deallocated")
                reply(response)
            }
        }
    }

    public func start() throws {
        try server.start()
        CasperLog.debug.debug("debug server listening")
    }

    public func stop() { server.stop() }

    private func handle(_ command: DebugCommand) -> DebugResponse {
        CasperLog.debug.debug("debug command: \(command.verb.rawValue, privacy: .public)")
        let surfaces = provider?.debugSurfaces() ?? []

        switch command.verb {
        case .dumpState:
            let entries = surfaces.map { handle -> DebugState.Surface in
                let (columns, rows) = handle.columnsRows()
                return DebugState.Surface(
                    title: handle.title, workingDirectory: handle.workingDirectory,
                    columns: columns, rows: rows, focused: handle.focused)
            }
            return .success(state: DebugState(surfaces: entries))

        case .readText:
            guard let target = focusedOrFirst(surfaces) else { return .failure("no surface") }
            guard let text = target.readText(command.scrollback ?? false) else {
                return .failure("read-text unavailable")
            }
            return .success(text: text)

        case .sendText:
            guard let target = focusedOrFirst(surfaces) else { return .failure("no surface") }
            guard let text = command.text else { return .failure("missing text") }
            target.sendText(command.enter == true ? text + "\n" : text)
            return .success()

        case .screenshot:
            guard let path = command.path else { return .failure("missing path") }
            guard let window = focusedOrFirst(surfaces)?.window else { return .failure("no window") }
            return screenshot(window: window, to: path)
        }
    }

    private func focusedOrFirst(_ surfaces: [DebugSurfaceHandle]) -> DebugSurfaceHandle? {
        surfaces.first(where: { $0.focused }) ?? surfaces.first
    }

    private func screenshot(window: NSWindow, to path: String) -> DebugResponse {
        let windowID = CGWindowID(window.windowNumber)
        // CGWindowListCreateImage is deprecated on macOS 14 but remains the only
        // reliable way to capture a Metal-rendered window's actual pixels; this
        // path is debug-only and never ships in release.
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return .failure("window capture failed")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return .failure("PNG encoding failed")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return .success(text: path)
        } catch {
            return .failure("write failed: \(error)")
        }
    }
}
#endif
```

- [ ] **Step 3: Build to verify it compiles (debug)**

Run: `swift build`
Expected: build succeeds (debug config → `#if DEBUG` code compiled).

- [ ] **Step 4: Verify it is absent from release**

Run: `swift build -c release 2>&1 | tail -5`
Expected: build succeeds; `DebugServer` is compiled out (no errors from its
absence, since nothing references it outside `#if DEBUG`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGhostty/DebugServer.swift Sources/CasperGhostty/GhosttySurfaceView.swift
git commit -m "Add DebugServer dispatcher and DebugSurfaceProvider (debug builds only)"
```

---

## Task 6: Wire `DebugServer` into `GhosttyDemo`

**Files:**
- Modify: `Sources/CasperGhostty/GhosttyDemo.swift`

**Interfaces:**
- Consumes: `DebugServer`, `DebugSurfaceProvider`, `DebugSurfaceHandle` (Task 5); `DebugSocketPath` (Task 3); the view's `#if DEBUG` accessors (Task 5).

Verified by the Task 8 GUI harness. Build to check compilation in both configs.

- [ ] **Step 1: Hold the view and start the server**

In `DemoDelegate`, add a stored reference to the view and, under `#if DEBUG`, the
server. Change the property block:

```swift
private final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let directory: String
    private var window: NSWindow?
    private var runtime: GhosttyRuntime?
    private var surfaceView: GhosttySurfaceView?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif
```

In `applicationDidFinishLaunching`, capture the view (replace the local `let view`
with an assignment to the stored property) and start the server after the window
is shown. Replace:

```swift
            let view = GhosttySurfaceView(runtime: runtime, configuration: config)
```

with:

```swift
            let view = GhosttySurfaceView(runtime: runtime, configuration: config)
            self.surfaceView = view
```

Then, immediately before the closing `}` of the `do { ... }` block (after
`self.window = window`), add:

```swift
            #if DEBUG
            startDebugServer()
            #endif
```

- [ ] **Step 2: Add the server bootstrap and provider conformance**

Append to `DemoDelegate` (inside the class):

```swift
    #if DEBUG
    private func startDebugServer() {
        let server = DebugServer(socketPath: DebugSocketPath.default, provider: self)
        do {
            try server.start()
            self.debugServer = server
        } catch {
            CasperLog.debug.error("debug server failed to start: \(String(describing: error))")
        }
    }
    #endif
```

Add the provider conformance as an extension at the bottom of the file:

```swift
#if DEBUG
extension DemoDelegate: DebugSurfaceProvider {
    func debugSurfaces() -> [DebugSurfaceHandle] {
        guard let view = surfaceView, view.debugHasSurface else { return [] }
        let window = self.window
        let focused = (window?.firstResponder === view)
        return [
            DebugSurfaceHandle(
                title: window?.title ?? "casper",
                workingDirectory: directory,
                focused: focused,
                readText: { [weak view] scrollback in view?.debugReadText(scrollback: scrollback) },
                sendText: { [weak view] text in view?.debugSendText(text) },
                columnsRows: { [weak view] in view?.debugColumnsRows() ?? (0, 0) },
                window: window),
        ]
    }
}
#endif
```

- [ ] **Step 3: Build both configurations**

Run: `swift build && swift build -c release`
Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add Sources/CasperGhostty/GhosttyDemo.swift
git commit -m "Start the debug server and expose the demo surface to it (debug builds)"
```

---

## Task 7: `casper debug` CLI subcommand

**Files:**
- Create: `Sources/CasperCLI/DebugCLICommand.swift`
- Modify: `Sources/CasperCLI/CasperCommand.swift`

**Interfaces:**
- Consumes: `DebugCommand`, `DebugResponse`, `DebugSocketClient`, `DebugSocketPath` (CasperCore).
- Produces: `struct DebugCLICommand: ParsableCommand` (command name `debug`) with subcommands `DumpState`, `ReadText`, `SendText`, `Screenshot` — all under `#if DEBUG`.

- [ ] **Step 1: Write the CLI subcommand**

```swift
// Sources/CasperCLI/DebugCLICommand.swift
#if DEBUG
import ArgumentParser
import CasperCore
import Foundation

/// `casper debug` — drive and observe the running GUI. Debug builds only.
struct DebugCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Drive and observe the running Casper GUI (debug builds only).",
        subcommands: [DumpState.self, ReadText.self, SendText.self, Screenshot.self])
}

/// Shared socket-path option.
struct SocketOption: ParsableArguments {
    @Option(name: .long, help: "Debug socket path (defaults to CASPER_DEBUG_SOCKET or /tmp/casper-debug.sock).")
    var socket: String?

    var path: String { socket ?? DebugSocketPath.default }
}

private func run(_ command: DebugCommand, socket: String) throws -> DebugResponse {
    let response = try DebugSocketClient.send(command, toSocketAt: socket)
    guard response.ok else {
        FileHandle.standardError.write(Data("error: \(response.error ?? "unknown")\n".utf8))
        throw ExitCode.failure
    }
    return response
}

extension DebugCLICommand {
    struct DumpState: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print app state as JSON.")
        @OptionGroup var socket: SocketOption

        func run() throws {
            let response = try CasperCLI.run(DebugCommand(verb: .dumpState), socket: socket.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response.state ?? DebugState(surfaces: []))
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct ReadText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the terminal's text.")
        @OptionGroup var socket: SocketOption
        @Flag(name: .long, help: "Include scrollback (full screen), not just the viewport.")
        var scrollback = false

        func run() throws {
            let response = try CasperCLI.run(
                DebugCommand(verb: .readText, scrollback: scrollback), socket: socket.path)
            print(response.text ?? "")
        }
    }

    struct SendText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inject text into the focused surface.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to send.") var text: String
        @Flag(name: .long, help: "Append a trailing newline (press Return).")
        var enter = false

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter), socket: socket.path)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String

        func run() throws {
            let response = try CasperCLI.run(
                DebugCommand(verb: .screenshot, path: path), socket: socket.path)
            print(response.text ?? path)
        }
    }
}
#endif
```

Note: the free `run(_:socket:)` helper is file-private to the module; the
subcommands call it as `CasperCLI.run(...)`. If the module qualifier causes a
name clash, rename the helper to `sendDebug(_:socket:)` and call it unqualified.

- [ ] **Step 2: Register the subcommand under `#if DEBUG`**

Replace the body of `Sources/CasperCLI/CasperCommand.swift` with:

```swift
import ArgumentParser

/// The root `casper` command. Ships the `casper hooks` family; `casper debug`
/// is added only in debug builds.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        subcommands: {
            var subs: [ParsableCommand.Type] = [HooksCommand.self]
            #if DEBUG
            subs.append(DebugCLICommand.self)
            #endif
            return subs
        }())

    public init() {}
}
```

- [ ] **Step 3: Build both configurations**

Run: `swift build && swift build -c release`
Expected: both succeed. In release, `casper debug` is not registered.

- [ ] **Step 4: Verify the subcommand is present in debug, absent in release**

Run:
```bash
swift build && .build/debug/casper debug --help | head -3
swift build -c release && .build/release/casper debug --help; echo "exit=$?"
```
Expected: the debug build prints the `debug` subcommand help; the release build
prints an "unknown subcommand/unexpected argument" error and a non-zero exit.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCLI/DebugCLICommand.swift Sources/CasperCLI/CasperCommand.swift
git commit -m "Add casper debug CLI subcommand (debug builds only)"
```

---

## Task 8: `debug-casper` project skill + end-to-end GUI verification

**Files:**
- Create: `.claude/skills/debug-casper/SKILL.md`

**Interfaces:**
- Consumes: everything above (`casper debug …`, `CasperLog` subsystem).

- [ ] **Step 1: Write the skill runbook**

```markdown
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
not include it. Everything below assumes a debug build (`make build`).

## 1. Build and launch

    make build
    .build/debug/casper >/tmp/casper.out 2>&1 &

The GUI binds a debug socket at `/tmp/casper-debug.sock` (override with
`CASPER_DEBUG_SOCKET`). Wait for it:

    until [ -S /tmp/casper-debug.sock ]; do sleep 0.2; done

## 2. Observe

Structured logs (subsystem `com.github.alexandreroman.casper`):

    log show --predicate 'subsystem == "com.github.alexandreroman.casper"' --last 2m --style compact
    # or live: log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' --style compact

App state as JSON:

    .build/debug/casper debug dump-state

The terminal's live text (viewport, or `--scrollback` for full screen):

    .build/debug/casper debug read-text
    .build/debug/casper debug read-text --scrollback

A screenshot (then read the PNG to "see" the window):

    .build/debug/casper debug screenshot /tmp/casper.png

## 3. Drive

Inject text into the focused surface (`--enter` presses Return):

    .build/debug/casper debug send-text 'echo hello' --enter

Then re-read to verify:

    .build/debug/casper debug read-text

## 4. Teardown

    kill %1 2>/dev/null; rm -f /tmp/casper-debug.sock

## Notes

- `read-text` returns the terminal contents as plain text — prefer it over
  screenshots for asserting terminal output.
- All verbs target the focused surface (falling back to the first surface).
```

- [ ] **Step 2: End-to-end verification (manual GUI harness)**

Run each and confirm the expected result:

```bash
make build
.build/debug/casper >/tmp/casper.out 2>&1 &
until [ -S /tmp/casper-debug.sock ]; do sleep 0.2; done

.build/debug/casper debug dump-state          # → JSON with one surface, columns/rows > 0
.build/debug/casper debug send-text 'echo casper-debug-ok' --enter
sleep 1
.build/debug/casper debug read-text            # → contains "casper-debug-ok"
.build/debug/casper debug screenshot /tmp/casper.png
file /tmp/casper.png                            # → "PNG image data"
log show --predicate 'subsystem == "com.github.alexandreroman.casper"' --last 1m --style compact | tail

kill %1 2>/dev/null; rm -f /tmp/casper-debug.sock
```

Expected: `dump-state` shows a surface with non-zero `columns`/`rows`;
`read-text` contains `casper-debug-ok`; `/tmp/casper.png` is a PNG; the log
shows a `debug command: …` line.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/debug-casper/SKILL.md
git commit -m "Add debug-casper skill documenting the app observe/drive runbook"
```

---

## Self-Review Notes

- **Spec coverage:** logging (Task 1) → §3.1; protocol (Task 2) + transport
  (Task 3) → §3.2 transport; surface introspection (Task 4) + dispatcher/verbs
  (Task 5) + GUI wiring (Task 6) → §3.2 verbs + server; CLI (Task 7) → §3.2 CLI
  surface; skill (Task 8) → §3.3; tests (Tasks 2, 3) → §4; `#if DEBUG` gating and
  logging floor enforced in every relevant task → §2.
- **Out of scope** (§5) — no mouse/click, no `send-key`, single focused-surface
  targeting — respected: `sendText` + `--enter` only.
- **Manual-only verification** for surface-bound code (Tasks 4–6, 8) matches how
  Plan 4 was verified; pure transport/protocol are unit-tested (Tasks 2–3).
```
