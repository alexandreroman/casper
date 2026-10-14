import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// End-to-end proof that a surface's queued `initialInput` runs in the user's real
/// login shell. `GhosttySurface.init` types it into the new PTY through
/// `ghostty_surface_text` — libghostty's own `initial_input` field stays unset (see
/// `GhosttySurfaceConfigurationTests.testInitialInputIsNotMarshaledIntoCStruct`) —
/// and the shell consumes it once it starts reading. This is the mechanism
/// `AppModel.surfaceView(for:in:)` relies on to run a terminal's launch command.
///
/// The typed text reaches the grid whether or not the shell runs it (the kernel
/// echoes it before the shell starts, then the line editor redraws it), so every
/// assertion matches output the typed text cannot contain: `$((40+1))` prints `41`,
/// `$0` prints the shell's name.
///
/// Runs on the shared `withRealSurface` harness (real `GhosttyRuntime`, offscreen
/// `NSWindow`, `XCTSkip` when no surface appears) with a fixed settle rather than
/// adaptive polling — see the `ghostty-real-surface-e2e-harness` note.
final class GhosttyInitialInputVerificationTests: XCTestCase {
    /// The queued text runs in the real login shell: `$0` starts with `-`, the
    /// login-shell marker, and names zsh. `$0` is read from the running shell, unlike
    /// `$SHELL`, which the surface inherits whatever shell actually starts.
    @MainActor
    func testInitialInputRunsInTheRealLoginShell() throws {
        // Which shell the surface launches is a fact about the host, not about Casper.
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        try XCTSkipUnless(loginShell.hasSuffix("/zsh"), "the host's login shell is \(loginShell), not zsh")

        let configuration = GhosttySurfaceConfiguration(initialInput: "echo INVOKER=$0\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertNotNil(
            grid.firstMatch(of: /INVOKER=-\S*zsh/),
            "expected the queued command to run in a zsh login shell; grid was:\n\(grid)")
    }

    /// The deliberate no-`exec` design decision: `AppModel` types a terminal's
    /// launch command as plain text, not `exec <command>`. A compound command
    /// must therefore run in full — regression coverage for the bonus bug found
    /// during investigation, where the old `bash -l -c "exec <command>"` path
    /// only ran the first part of `a ; b ; c` (because `exec a` never returns).
    @MainActor
    func testCompoundCommandRunsInFull() throws {
        let configuration = GhosttySurfaceConfiguration(
            initialInput: "echo PART_$((40+1)); echo PART_$((40+2)); echo PART_$((40+3))\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertTrue(grid.contains("PART_41"), "grid was:\n\(grid)")
        XCTAssertTrue(grid.contains("PART_42"), "grid was:\n\(grid)")
        XCTAssertTrue(grid.contains("PART_43"), "grid was:\n\(grid)")
    }

    /// Bring up a real PTY-backed surface for `configuration`, settle, and read back the
    /// visible grid. Skips (rather than fails) when libghostty can't produce a surface.
    @MainActor
    private func captureGrid(configuration: GhosttySurfaceConfiguration) throws -> String {
        var grid = ""
        try withRealSurface(makeView: { GhosttySurfaceView(runtime: $0, configuration: configuration) }) {
            _, surface in
            // On top of the harness's shell-ready settle, let the shell consume the queued
            // input and print its output before we read the grid.
            settle(0.4)

            grid = surface.readText(scrollback: false) ?? ""
        }
        return grid
    }
}
