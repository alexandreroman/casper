import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// End-to-end proof that the vendored libghostty fork honors `initial_input`:
/// with only `initialInput` (no explicit command), it launches the user's real
/// login shell (zsh) and queues the given text into the PTY as if typed. This is
/// the mechanism `AppModel.surfaceView(for:in:)` relies on to run a terminal's
/// launch command reliably.
///
/// Runs on the shared `withRealSurface` harness (real `GhosttyRuntime()`, offscreen
/// `NSWindow`, `XCTSkip` when no surface appears) with a fixed settle rather than
/// adaptive polling — see the `ghostty-real-surface-e2e-harness` note.
final class GhosttyInitialInputVerificationTests: XCTestCase {
    /// With only `initialInput` carrying a probe (no explicit command), the grid must
    /// show the real login shell ran (`$0` starts with `-`, the login-shell marker,
    /// and contains `zsh`) and its dotfiles were sourced (Homebrew's
    /// `/opt/homebrew/bin` on PATH, added only by `~/.zprofile`/`~/.zshrc`).
    @MainActor
    func testInitialInputRunsRealLoginShellWithZshPath() throws {
        let configuration = GhosttySurfaceConfiguration(
            initialInput: "echo INVOKER=$0 SHELL=$SHELL; echo PATH=$PATH\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertTrue(
            grid.contains("INVOKER="),
            "initial_input probe did not run; grid was:\n\(grid)")

        // Which shell and which Homebrew prefix the surface inherits are facts about the
        // host, not about Casper, so the two assertions below only apply where they can
        // mean something.
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        try XCTSkipUnless(
            loginShell.hasSuffix("/zsh"), "the host's login shell is \(loginShell), not zsh")
        XCTAssertTrue(
            grid.contains("zsh"),
            "expected the real login shell (zsh), not bash; grid was:\n\(grid)")

        let homebrewBin = "/opt/homebrew/bin"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: homebrewBin),
            "the host has no Homebrew at \(homebrewBin)")
        XCTAssertTrue(
            grid.contains(homebrewBin),
            "expected Homebrew's zsh-dotfile PATH entry; grid was:\n\(grid)")
    }

    /// A command containing `exec` must still just be typed text — `initial_input`
    /// has no special `exec` handling of its own (that was `command`'s broken
    /// behavior). This only confirms the literal text reaches the shell; it does
    /// not by itself prove process-replacement semantics either way.
    @MainActor
    func testInitialInputExecMarkerAppears() throws {
        let configuration = GhosttySurfaceConfiguration(
            initialInput: "exec echo EXEC_MARKER_$$\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertTrue(
            grid.contains("EXEC_MARKER_"),
            "exec initial_input marker did not appear; grid was:\n\(grid)")
    }

    /// The deliberate no-`exec` design decision: `AppModel` types a terminal's
    /// launch command as plain text, not `exec <command>`. A compound command
    /// must therefore run in full — regression coverage for the bonus bug found
    /// during investigation, where the old `bash -l -c "exec <command>"` path
    /// only ran the first part of `a ; b ; c` (because `exec a` never returns).
    @MainActor
    func testCompoundCommandRunsInFull() throws {
        let configuration = GhosttySurfaceConfiguration(
            initialInput: "echo PART_A; echo PART_B; echo PART_C\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertTrue(grid.contains("PART_A"), "grid was:\n\(grid)")
        XCTAssertTrue(grid.contains("PART_B"), "grid was:\n\(grid)")
        XCTAssertTrue(grid.contains("PART_C"), "grid was:\n\(grid)")
    }

    /// Bring up a real PTY-backed surface for `configuration`, settle, and read back the
    /// visible grid. Skips (rather than fails) when libghostty can't produce a surface.
    @MainActor
    private func captureGrid(configuration: GhosttySurfaceConfiguration) throws -> String {
        var grid = ""
        try withRealSurface(makeView: { GhosttySurfaceView(runtime: $0, configuration: configuration) }) {
            _, surface in
            // Let the shell reach an interactive prompt, consume the queued initial_input,
            // and print its output before we read the grid.
            settle(1.0)

            grid = surface.readText(scrollback: false) ?? ""
        }
        return grid
    }
}
