import XCTest
import Darwin
import Foundation
@testable import CasperGit

// Sink for the faulting read. A module-level `var` the test reads back keeps the
// compiler from eliding the load that must trigger the SIGBUS.
private nonisolated(unsafe) var sigbusReadSink: UInt8 = 0

final class SigbusGuardTests: XCTestCase {
    /// Runs `body` under the guard and returns true if a SIGBUS was caught
    /// (i.e. `run` threw). The guard rethrows non-SIGBUS errors and success
    /// values, so any throw in this test corresponds to a caught fault.
    private func didCatchFault(_ body: @escaping () -> Void) -> Bool {
        do {
            try SigbusGuard.run(body)
            return false
        } catch {
            return true
        }
    }

    func testGuardReturnsBodyValueOnNormalPath() throws {
        let value = try SigbusGuard.run { 42 }
        XCTAssertEqual(value, 42)
    }

    func testGuardRethrowsBodyError() {
        struct Boom: Error {}
        XCTAssertThrowsError(try SigbusGuard.run { throw Boom() }) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testGuardConvertsSigbusIntoThrownError() throws {
        // Map one page of a real file, truncate the file to zero, then touch the
        // mapping: reading a page with no backing store past EOF raises SIGBUS on
        // Darwin. This is deterministic — no timing races.
        let path = NSTemporaryDirectory() + "casper-sigbus-\(UUID().uuidString)"
        defer { unlink(path) }

        let pageSize = 4096
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0, "failed to open temp file")
        defer { close(fd) }
        XCTAssertEqual(ftruncate(fd, off_t(pageSize)), 0, "failed to size temp file")

        let mapping = mmap(nil, pageSize, PROT_READ, MAP_SHARED, fd, 0)
        XCTAssertNotEqual(mapping, MAP_FAILED, "mmap failed")
        defer { munmap(mapping, pageSize) }

        // Shrink the file so the mapped page no longer has backing store.
        XCTAssertEqual(ftruncate(fd, 0), 0, "failed to truncate temp file")

        let mappedBytes = mapping!.assumingMemoryBound(to: UInt8.self)
        let caughtFault = didCatchFault {
            // Read a now-unbacked page: this is the SIGBUS. The result flows into
            // a module-level sink so the load is not optimized away.
            sigbusReadSink = mappedBytes[0]
        }
        XCTAssertTrue(caughtFault, "expected the guard to catch the SIGBUS")
        // Reference the sink so the store (and therefore the load) is observable.
        XCTAssertEqual(sigbusReadSink, 0)

        // The thread-local jump state must be restored after a caught fault, so a
        // subsequent guarded run still works on this same thread.
        let after = try SigbusGuard.run { 7 }
        XCTAssertEqual(after, 7)
    }
}
