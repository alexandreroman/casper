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
}
