import XCTest
import CasperCore
@testable import CasperUI

/// Unit tests for `BrowserCoordinator`'s console ring buffer, driven through the
/// `#if DEBUG` `debugAppendConsole` seam so no live page is needed: ring-buffer
/// cap (drop oldest), severity-threshold filtering, and drain-on-clear.
@MainActor
final class BrowserConsoleBufferTests: XCTestCase {
    private func makeCoordinator() -> BrowserCoordinator {
        BrowserCoordinator(surfaceID: UUID(), url: URL(string: "about:blank")!)
    }

    private func entry(_ level: String, _ message: String) -> ConsoleEntry {
        ConsoleEntry(level: level, message: message, timestamp: 0)
    }

    func testRingBufferDropsOldestBeyondCapacity() {
        let coordinator = makeCoordinator()
        for i in 0..<501 { coordinator.debugAppendConsole(entry("log", "m\(i)")) }
        let snapshot = coordinator.consoleSnapshot(level: nil, clear: false)
        XCTAssertEqual(snapshot.count, 500)
        XCTAssertEqual(snapshot.first?.message, "m1", "the oldest (m0) entry should have been dropped")
        XCTAssertEqual(snapshot.last?.message, "m500")
    }

    func testLevelThresholdKeepsAtOrAboveOnly() {
        let coordinator = makeCoordinator()
        for level in ["debug", "log", "info", "warn", "error"] {
            coordinator.debugAppendConsole(entry(level, level))
        }
        XCTAssertEqual(coordinator.consoleSnapshot(level: .warn, clear: false).map(\.message), ["warn", "error"])
        XCTAssertEqual(
            coordinator.consoleSnapshot(level: .debug, clear: false).map(\.message),
            ["debug", "log", "info", "warn", "error"])
    }

    func testClearDrainsWholeBufferRegardlessOfFilter() {
        let coordinator = makeCoordinator()
        coordinator.debugAppendConsole(entry("debug", "d"))
        coordinator.debugAppendConsole(entry("error", "e"))
        // A filtered read that also clears returns only the filtered entries, but
        // still drains the ENTIRE buffer (the drain is unconditional).
        let filtered = coordinator.consoleSnapshot(level: .error, clear: true)
        XCTAssertEqual(filtered.map(\.message), ["e"])
        XCTAssertTrue(coordinator.consoleSnapshot(level: nil, clear: false).isEmpty)
    }
}
