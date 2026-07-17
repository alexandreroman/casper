import Foundation
import XCTest

@testable import CasperCore

/// Drives the watchdog's detection state machine synchronously through its
/// injectable seams — a fake clock, a manual main-thread ack toggle and a stubbed
/// capture — so no real timer, blocked main thread or `sample` subprocess is
/// involved. Each `handleTick()` call models one 500 ms timer tick.
final class MainThreadHangWatchdogTests: XCTestCase {

    /// A hand-driven fake clock and ack switch shared with the watchdog under test.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now: TimeInterval = 0
        private var _mainResponsive = true
        private var _captures: [(hangDuration: TimeInterval, destination: URL)] = []

        var now: TimeInterval {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        /// When true, the ack block runs immediately (main thread alive); when
        /// false, it is dropped (main thread hung).
        var mainResponsive: Bool {
            get { lock.withLock { _mainResponsive } }
            set { lock.withLock { _mainResponsive = newValue } }
        }
        var captures: [(hangDuration: TimeInterval, destination: URL)] {
            lock.withLock { _captures }
        }
        func advance(by delta: TimeInterval) { lock.withLock { _now += delta } }
        func recordCapture(_ hangDuration: TimeInterval, _ destination: URL) {
            lock.withLock { _captures.append((hangDuration, destination)) }
        }
    }

    private func makeWatchdog(threshold: TimeInterval = 2.0) -> (MainThreadHangWatchdog, Harness) {
        let harness = Harness()
        let watchdog = MainThreadHangWatchdog(threshold: threshold)
        watchdog.nowProvider = { harness.now }
        watchdog.scheduleAck = { block in
            if harness.mainResponsive { block() }  // hung main thread never runs the ack
        }
        watchdog.captureDispatch = { block in block() }  // run capture inline for determinism
        watchdog.capture = { hangDuration, destination in harness.recordCapture(hangDuration, destination) }
        return (watchdog, harness)
    }

    func testNoCaptureWhileMainThreadKeepsAcking() {
        let (watchdog, harness) = makeWatchdog(threshold: 2.0)

        for _ in 0..<20 {
            harness.advance(by: 0.5)
            watchdog.handleTick()
        }

        XCTAssertTrue(harness.captures.isEmpty)
    }

    func testCaptureFiresExactlyOncePerHangEpisode() {
        let (watchdog, harness) = makeWatchdog(threshold: 2.0)

        // Baseline ack (mirrors what start() does), then the main thread stops
        // acking and the measured gap grows past the threshold.
        watchdog.handleTick()
        harness.mainResponsive = false
        for _ in 0..<10 {
            harness.advance(by: 0.5)
            watchdog.handleTick()
        }

        XCTAssertEqual(harness.captures.count, 1, "one hang episode must yield exactly one capture")
        // The reported duration reflects the elapsed gap at the crossing tick.
        XCTAssertGreaterThanOrEqual(harness.captures[0].hangDuration, 2.0)
    }

    func testCaptureReArmsAfterRecoveryAndNewStall() {
        let (watchdog, harness) = makeWatchdog(threshold: 2.0)

        // Baseline ack, then the first hang episode → one capture.
        watchdog.handleTick()
        harness.mainResponsive = false
        for _ in 0..<8 {
            harness.advance(by: 0.5)
            watchdog.handleTick()
        }
        XCTAssertEqual(harness.captures.count, 1)

        // Main thread recovers: the next tick's ack runs and re-arms the watchdog.
        harness.mainResponsive = true
        harness.advance(by: 0.5)
        watchdog.handleTick()
        XCTAssertEqual(harness.captures.count, 1, "recovery must not itself trigger a capture")

        // Second hang episode → a second capture, proving re-arm works.
        harness.mainResponsive = false
        for _ in 0..<8 {
            harness.advance(by: 0.5)
            watchdog.handleTick()
        }
        XCTAssertEqual(harness.captures.count, 2)
    }
}
