import AppKit
import Foundation
import XCTest

@testable import CasperGhostty

/// A surface whose creation failed while every display was asleep must recover on its
/// own once the displays come back, without waiting for a re-parent.
///
/// The `.forTesting()` runtime fails every creation attempt, which stands in for the
/// display-asleep failure: hosting a view exhausts its bounded retries and shows the
/// error overlay. The tests then post the wake notifications AppKit would post and
/// read the creation state back through the view's debug seams.
final class GhosttyDisplayWakeTests: XCTestCase {
    /// Holds the host window for the duration of the test: the view only keeps a weak
    /// reference to its window, and a window released mid-test would look to the view
    /// like a detach.
    @MainActor private var hostWindow: NSWindow?

    /// The view under test, invalidated in `tearDown` so no armed retry outlives it.
    @MainActor private var hostedView: GhosttySurfaceView?

    @MainActor
    override func tearDown() async throws {
        hostedView?.invalidate()
        hostWindow?.contentView = nil
        hostedView = nil
        hostWindow = nil
        try await super.tearDown()
    }

    /// Raised when a creation cycle never gives up. The `.forTesting()` runtime fails
    /// every attempt, so this is a regression in the retry chain, not the environment.
    private struct CreationCycleNeverExhausted: Error {}

    /// Host a view in a borderless offscreen window. Hosting makes the first creation
    /// attempt synchronously; it fails and arms the first 0.25 s retry.
    @MainActor
    private func makeHostedView() -> GhosttySurfaceView {
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> the first attempt
        hostWindow = window
        hostedView = view
        return view
    }

    /// Pump the run loop until the view's current creation cycle gives up (three
    /// attempts, 0.25 s apart), failing the test if it never does.
    @MainActor
    private func waitForExhaustedCreation(of view: GhosttySurfaceView) throws {
        let deadline = Date().addingTimeInterval(5)
        while !view.debugShowsErrorOverlay, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard view.debugShowsErrorOverlay else {
            XCTFail("the creation cycle never gave up")
            throw CreationCycleNeverExhausted()
        }
        XCTAssertEqual(view.debugSurfaceCreationAttempts, 3)
    }

    /// A hosted view whose first creation cycle has already given up.
    @MainActor
    private func makeViewWithExhaustedCreation() throws -> GhosttySurfaceView {
        let view = makeHostedView()
        try waitForExhaustedCreation(of: view)
        return view
    }

    /// Let a `queue: .main` observer run, staying well inside the 0.25 s retry delay so
    /// a restarted cycle is observed after its first attempt only.
    @MainActor
    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @MainActor
    func testScreensDidWakeRestartsExhaustedCreation() throws {
        let view = try makeViewWithExhaustedCreation()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        drainMainQueue()

        // A fresh cycle: the overlay is cleared and the budget restarts from one attempt.
        XCTAssertFalse(view.debugShowsErrorOverlay)
        XCTAssertEqual(view.debugSurfaceCreationAttempts, 1)
    }

    @MainActor
    func testScreenParametersChangeRestartsExhaustedCreation() throws {
        let view = try makeViewWithExhaustedCreation()

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        drainMainQueue()

        XCTAssertFalse(view.debugShowsErrorOverlay)
        XCTAssertEqual(view.debugSurfaceCreationAttempts, 1)
    }

    /// A wake that lands while a retry is still armed restarts the cycle without leaving
    /// the old retry running beside the new one: the attempts follow a single chain.
    @MainActor
    func testDisplayWakeMidCycleRestartsASingleRetryChain() throws {
        let view = makeHostedView()
        XCTAssertEqual(view.debugTotalSurfaceCreationAttempts, 1)
        XCTAssertFalse(view.debugShowsErrorOverlay)

        // Posted before the run loop has turned, so the armed 0.25 s retry cannot have
        // fired yet: the wake reliably lands mid-cycle.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        drainMainQueue()

        try waitForExhaustedCreation(of: view)
        // Outlast another full retry window so a stray retry chain, had one survived,
        // would have fired by now.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        // The first attempt plus one restarted cycle of three. An ignored wake would
        // read 3; an old retry left running beside the new chain would push it past 4.
        XCTAssertEqual(view.debugTotalSurfaceCreationAttempts, 4)
        XCTAssertEqual(view.debugSurfaceCreationAttempts, 3)
    }

    /// `invalidate()` is final: a wake must not start creating a surface for a view its
    /// owner has already torn down.
    @MainActor
    func testInvalidatedViewIgnoresDisplayWake() throws {
        let view = try makeViewWithExhaustedCreation()
        view.invalidate()

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        drainMainQueue()

        XCTAssertTrue(view.debugShowsErrorOverlay)
        XCTAssertEqual(view.debugSurfaceCreationAttempts, 3)
    }

    /// A detached view cannot host a surface; it starts its own cycle when it re-enters
    /// a window, so a wake while detached must leave it alone.
    @MainActor
    func testDetachedViewIgnoresDisplayWake() throws {
        let view = try makeViewWithExhaustedCreation()
        hostWindow?.contentView = nil

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        drainMainQueue()

        XCTAssertEqual(view.debugSurfaceCreationAttempts, 3)
    }
}
