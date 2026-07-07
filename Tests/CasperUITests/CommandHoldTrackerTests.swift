import XCTest
@testable import CasperUI

@MainActor
final class CommandHoldTrackerTests: XCTestCase {
    private final class FakeToken: HoldTimerToken {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    func testRevealsAfterTimerFires() {
        var revealed: [Bool] = []
        var firedClosure: (() -> Void)?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { interval, fire in
                XCTAssertEqual(interval, 1.0)
                firedClosure = fire
                return FakeToken()
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        XCTAssertTrue(revealed.isEmpty, "must not reveal before the timer fires")
        firedClosure?()
        XCTAssertEqual(revealed, [true])
    }

    func testReleasingBeforeTimerFiresCancelsAndNeverReveals() {
        var revealed: [Bool] = []
        var cancelledToken: FakeToken?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, _ in
                let token = FakeToken()
                cancelledToken = token
                return token
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        tracker.commandKeyUp()

        XCTAssertEqual(cancelledToken?.cancelled, true)
        XCTAssertEqual(revealed, [false])
    }

    func testReleasingAfterRevealHidesHints() {
        var revealed: [Bool] = []
        var firedClosure: (() -> Void)?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, fire in
                firedClosure = fire
                return FakeToken()
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        firedClosure?()
        tracker.commandKeyUp()

        XCTAssertEqual(revealed, [true, false])
    }

    func testSecondKeyDownWhileTimerPendingDoesNotRestartTimer() {
        var scheduleCount = 0
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, _ in
                scheduleCount += 1
                return FakeToken()
            },
            onRevealChange: { _ in }
        )

        tracker.commandKeyDown()
        tracker.commandKeyDown()

        XCTAssertEqual(scheduleCount, 1)
    }

    func testSecondKeyDownAfterRevealDoesNotRescheduleOrRevealAgain() {
        var scheduleCount = 0
        var revealed: [Bool] = []
        var firedClosure: (() -> Void)?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, fire in
                scheduleCount += 1
                firedClosure = fire
                return FakeToken()
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        firedClosure?()
        // A stray key-down (e.g. an unrelated modifier's flagsChanged) while
        // Cmd is still held must not re-arm the timer or reveal a second time.
        tracker.commandKeyDown()

        XCTAssertEqual(scheduleCount, 1)
        XCTAssertEqual(revealed, [true])
    }

    func testCommandKeyUpWhileIdleDoesNotCallOnRevealChange() {
        var revealed: [Bool] = []
        let tracker = CommandHoldTracker(holdDuration: 1.0) { revealed.append($0) }

        tracker.commandKeyUp()

        XCTAssertTrue(revealed.isEmpty)
    }
}
