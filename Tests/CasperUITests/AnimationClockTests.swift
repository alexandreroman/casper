import XCTest
@testable import CasperUI

final class AnimationClockTests: XCTestCase {
    func testZeroElapsedReturnsZeroDelay() {
        let epoch = Date()
        let delay = AnimationClock.phaseDelay(period: 1, now: epoch, epoch: epoch)
        XCTAssertEqual(delay, 0, accuracy: 0.0001)
    }

    func testPartialCycleReturnsNegativeElapsed() {
        let epoch = Date()
        let now = epoch.addingTimeInterval(0.3)
        let delay = AnimationClock.phaseDelay(period: 1, now: now, epoch: epoch)
        XCTAssertEqual(delay, -0.3, accuracy: 0.0001)
    }

    func testElapsedPastOnePeriodWrapsAround() {
        let epoch = Date()
        let now = epoch.addingTimeInterval(1.3)
        let delay = AnimationClock.phaseDelay(period: 1, now: now, epoch: epoch)
        XCTAssertEqual(delay, -0.3, accuracy: 0.0001)
    }

    func testResultAlwaysInOpenRange() {
        let epoch = Date()
        for elapsed in stride(from: 0.0, to: 5.0, by: 0.37) {
            let now = epoch.addingTimeInterval(elapsed)
            let delay = AnimationClock.phaseDelay(period: 1.6, now: now, epoch: epoch)
            XCTAssertGreaterThan(delay, -1.6)
            XCTAssertLessThanOrEqual(delay, 0)
        }
    }
}
