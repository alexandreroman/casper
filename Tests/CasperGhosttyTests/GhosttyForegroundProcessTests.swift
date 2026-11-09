import AppKit
import Foundation
import XCTest
import CasperCore
import CasperTestSupport

@testable import CasperGhostty

/// The foreground-process accessor, and the live PTY facts agent detection rests on:
/// the shell at its prompt is alone in its group, and a job it runs takes the
/// foreground until it exits.
final class GhosttyForegroundProcessTests: XCTestCase {
    func testUnknownForegroundIsNil() {
        XCTAssertNil(GhosttySurface.processID(fromForegroundPID: 0))
    }

    func testForegroundOutOfPIDRangeIsNil() {
        XCTAssertNil(GhosttySurface.processID(fromForegroundPID: UInt64(pid_t.max) + 1))
        XCTAssertNil(GhosttySurface.processID(fromForegroundPID: .max))
    }

    func testForegroundInRangeIsThePID() {
        XCTAssertEqual(GhosttySurface.processID(fromForegroundPID: 4242), 4242)
        XCTAssertEqual(GhosttySurface.processID(fromForegroundPID: UInt64(pid_t.max)), pid_t.max)
    }

    @MainActor
    func testViewWithoutSurfaceHasNoForeground() {
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.invalidate()
        XCTAssertNil(view.readForegroundPID())
    }

    /// A link named `claude` to `/bin/sleep` stands in for the agent: identification
    /// reads argv[0] and the exec path as invoked, which is what names native Claude
    /// Code too (its image is a versioned file). Fixed settles, not polling (see the
    /// `ghostty-real-surface-e2e-harness` note).
    @MainActor
    func testForegroundFollowsAnAgentRunAndItsExit() throws {
        let fakeAgent = try makeFakeAgent()
        let inspector = LibprocProcessInspector()
        var tracker = ForegroundTracker()
        let surfaceID = UUID()

        try withRealSurface { view, _ in
            // On top of the harness's settle: the user's shell startup can still have a
            // helper in the shell's own group (a prompt's `$(…)`), which is `.other`.
            settle(1)
            let shellPID = try XCTUnwrap(view.readForegroundPID(), "a live shell has a foreground group")
            let shell = inspector.snapshot(of: shellPID)
            XCTAssertEqual(
                ForegroundProcessClassifier.classify(shell, shellNames: inspector.shellNames), .shell,
                "the shell at its prompt leads a group of its own")
            XCTAssertEqual(
                tracker.observe(surface: surfaceID, foregroundPID: view.readForegroundPID(), inspector: inspector),
                ForegroundObservation(process: .shell, agentExited: false))

            view.debugSendText("'\(fakeAgent.path)' 3", submit: true)
            settle(1)
            XCTAssertEqual(
                tracker.observe(surface: surfaceID, foregroundPID: view.readForegroundPID(), inspector: inspector),
                ForegroundObservation(process: .agent(.claudeCode), agentExited: false))

            // The job sleeps 3 s from ~1 s ago; the extra second lets the shell reclaim
            // the terminal.
            settle(3)
            XCTAssertEqual(
                tracker.observe(surface: surfaceID, foregroundPID: view.readForegroundPID(), inspector: inspector),
                ForegroundObservation(process: .shell, agentExited: true))
        }
    }

    /// `<temp>/claude`, a symbolic link to `/bin/sleep`. Not a copy: the kernel kills a
    /// copied platform binary on launch.
    private func makeFakeAgent() throws -> URL {
        let fakeAgent = makeTemporaryDirectory(prefix: "casper-foreground").appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: fakeAgent, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        return fakeAgent
    }
}
