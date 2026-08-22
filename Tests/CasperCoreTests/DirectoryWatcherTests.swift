import os
import XCTest
@testable import CasperCore

final class DirectoryWatcherTests: XCTestCase {
    // Best-effort integration test: FSEvents delivery timing is inherently
    // asynchronous and can make this mildly flaky, hence the generous timeout.
    func testFiresOnFileCreation() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("casper-watcher-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let expectation = expectation(description: "onChange fires")
        expectation.assertForOverFulfill = false
        // The callback runs on the watcher's serial queue (off the main thread);
        // fulfilling an XCTestExpectation from there is safe.
        let watcher = DirectoryWatcher(path: dir.path) {
            expectation.fulfill()
        }
        XCTAssertNotNil(watcher)
        defer { watcher?.stop() }

        let file = dir.appendingPathComponent("change.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        wait(for: [expectation], timeout: 5)
    }

    /// `deinit` calls `stop()` unconditionally, and releasing the last reference
    /// from within the callback runs `deinit` on the watcher's own serial queue.
    /// `stop()`'s drain barrier must therefore be skipped when it is already on
    /// that queue, or teardown deadlocks. Calling `stop()` from the callback
    /// reproduces exactly that situation.
    func testStopFromTheCallbackQueueDoesNotDeadlock() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("casper-watcher-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let returned = expectation(description: "stop() returns from the callback queue")
        returned.assertForOverFulfill = false
        // The callback needs the watcher the initializer is still constructing, so
        // it reads it from a lock-guarded box the caller fills in right after.
        let box = OSAllocatedUnfairLock<DirectoryWatcher?>(initialState: nil)
        let watcher = DirectoryWatcher(path: dir.path) {
            box.withLock { $0 }?.stop()
            returned.fulfill()
        }
        XCTAssertNotNil(watcher)
        box.withLock { $0 = watcher }
        // The box holds the watcher, which holds the callback, which captures the box:
        // emptying the box breaks that cycle so the watcher and its queue are released.
        defer { box.withLock { $0 = nil } }
        defer { watcher?.stop() }

        try "hello".write(to: dir.appendingPathComponent("change.txt"), atomically: true, encoding: .utf8)

        wait(for: [returned], timeout: 5)
    }
}
