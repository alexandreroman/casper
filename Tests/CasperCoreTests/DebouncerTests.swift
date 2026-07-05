import XCTest
@testable import CasperCore

@MainActor
final class DebouncerTests: XCTestCase {
    func testCoalescesBurstIntoASingleFire() {
        let debouncer = Debouncer(delay: 0.05)
        let expectation = expectation(description: "action fires once")
        var fireCount = 0

        // A burst of schedules within the window must collapse to one fire.
        for _ in 0..<5 {
            debouncer.schedule {
                fireCount += 1
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(fireCount, 1)
    }

    func testCancelPreventsPendingFire() {
        let debouncer = Debouncer(delay: 0.05)
        var fired = false
        debouncer.schedule { fired = true }
        debouncer.cancel()

        // Wait past the delay to confirm the cancelled action never runs.
        let expectation = expectation(description: "delay elapses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(fired)
    }
}
