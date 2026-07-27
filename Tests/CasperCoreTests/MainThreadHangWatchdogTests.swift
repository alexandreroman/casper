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

    // MARK: The real `scheduleAck` default
    //
    // The three tests above stub `scheduleAck` out. These two exercise the real
    // one, because its exact delivery mechanism *is* the fix: acks ride the main
    // run loop instead of the main dispatch queue so that a nested modal loop —
    // Sparkle's "Check for Updates…" alert, Casper's own `runModal()` panels,
    // menu tracking — no longer looks like a hung main thread.

    /// The ack must survive a modal session: scheduled from the watchdog's
    /// background queue, it has to run on a main run loop that is only turning in
    /// `NSModalPanelRunLoopMode`.
    func testDefaultScheduleAckIsDeliveredWhileOnlyTheModalPanelModeRuns() {
        let scheduleAck = MainThreadHangWatchdog().scheduleAck  // the real default, not a stub
        let acked = Flag()

        let keepAlive = addKeepAliveTimer(forModes: [.init(MainThreadHangWatchdog.modalPanelRunLoopMode)])
        defer { keepAlive.invalidate() }

        DispatchQueue.global().async { scheduleAck { acked.set() } }

        XCTAssertTrue(
            pumpMainRunLoop(in: modalPanelMode, until: { acked.isSet }),
            "the ack must be delivered by a run loop turning only in the modal panel mode")
    }

    /// Negative control reproducing the false positive this fix removes, by the
    /// same mechanism the Sparkle dump showed: a block already running on the main
    /// queue spins a nested run loop, and libdispatch refuses to re-enter
    /// `_dispatch_main_queue_drain` from it. The nested loop deliberately runs in
    /// the *default* mode — the very mode that services the main queue's drain
    /// source — so the only thing keeping the queued block out is that
    /// re-entrancy guard. The run loop block scheduled alongside it gets through.
    ///
    /// Both verdicts are sampled *inside* the outer main queue block, while the
    /// drain that runs it is still on the stack: that is the only window in which
    /// "the queued block has not run" provably means "the nested loop refused to
    /// run it". Once the outer block returns, the drain is free to pick the queued
    /// block up, so the live flag would no longer be evidence of anything.
    func testMainQueueAckWouldBeStarvedByANestedRunLoopButARunLoopAckIsNot() {
        let scheduleAck = MainThreadHangWatchdog().scheduleAck
        let runLoopAcked = Flag()
        let mainQueueAcked = Flag()
        let runLoopAckedInsideNestedLoop = Flag()
        let mainQueueAckedInsideNestedLoop = Flag()
        let modalDone = Flag()

        let keepAlive = addKeepAliveTimer(forModes: [.default])
        defer { keepAlive.invalidate() }

        // Stands in for Sparkle's `-[NSAlert runModal]`: main queue work that
        // parks the main thread in a nested run loop waiting for the user.
        DispatchQueue.main.async {
            scheduleAck { runLoopAcked.set() }
            DispatchQueue.main.async { mainQueueAcked.set() }
            _ = pumpMainRunLoop(in: .defaultMode, until: { runLoopAcked.isSet }, budget: 1.0)
            // Snapshot before returning — see the note above.
            if runLoopAcked.isSet { runLoopAckedInsideNestedLoop.set() }
            if mainQueueAcked.isSet { mainQueueAckedInsideNestedLoop.set() }
            modalDone.set()
        }

        // Drive the outer main queue block from the test thread, which is *not*
        // itself inside the main queue drain.
        XCTAssertTrue(
            pumpMainRunLoop(in: .defaultMode, until: { modalDone.isSet }, budget: 3.0),
            "the simulated modal block must get a chance to run")

        XCTAssertTrue(runLoopAckedInsideNestedLoop.isSet, "a run loop block is drained by the nested loop")
        XCTAssertFalse(
            mainQueueAckedInsideNestedLoop.isSet,
            "a main queue block is not — this is exactly why the watchdog used to report a phantom hang")
    }
}

// MARK: Run loop test helpers
//
// File-scope rather than methods on the test case: the negative control calls
// them from inside a main queue block, and capturing `self` there trips Swift 6
// sending-risks-data-races.

/// A one-shot flag a block can set from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// AppKit's `NSModalPanelRunLoopMode`, as the `CFRunLoopMode` the pump takes.
private let modalPanelMode = CFRunLoopMode(rawValue: MainThreadHangWatchdog.modalPanelRunLoopMode as CFString)

/// Turns the main run loop in `mode` — and only in `mode` — in short slices,
/// until `condition` holds or the budget runs out. Returns whether it held.
private func pumpMainRunLoop(
    in mode: CFRunLoopMode, until condition: () -> Bool, budget: TimeInterval = 2.0
) -> Bool {
    let deadline = Date().addingTimeInterval(budget)
    while !condition() && Date() < deadline {
        CFRunLoopRunInMode(mode, 0.02, true)
    }
    return condition()
}

/// Keeps `modes` non-empty for the returned timer's lifetime: `CFRunLoopRunInMode`
/// returns `kCFRunLoopRunFinished` immediately for a mode holding no sources or
/// timers, and pending blocks alone do not count as content — so without this the
/// pumps above would spin out without ever running the block under test.
private func addKeepAliveTimer(forModes modes: [RunLoop.Mode]) -> Timer {
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in }
    for mode in modes { RunLoop.main.add(timer, forMode: mode) }
    return timer
}
