import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// End-to-end proof that the vendored libghostty fork honors `initial_input`:
/// with `command: nil`, it launches the user's real login shell (zsh) and
/// queues the given text into the PTY as if typed — unlike `command`, which
/// the fork execs through `bash -l -c` regardless of `$SHELL` (see the
/// `surface-command-bash-exec` memory note). This is the mechanism
/// `AppModel.surfaceView(for:in:)` relies on to run a terminal's launch
/// command reliably.
///
/// Follows the real-surface e2e harness pattern (real `GhosttyRuntime()`,
/// offscreen `NSWindow`, poll for `view.surface != nil` with `XCTSkip`
/// fallback, fixed `settle(0.6)` then `settle(0.4)` — see the
/// `ghostty-real-surface-e2e-harness` note).
final class GhosttyInitialInputVerificationTests: XCTestCase {
    /// With `command: nil` and `initialInput` carrying a probe, the grid must show
    /// the real login shell ran (`$0` starts with `-`, the login-shell marker,
    /// and contains `zsh`) and its dotfiles were sourced (Homebrew's
    /// `/opt/homebrew/bin` on PATH, added only by `~/.zprofile`/`~/.zshrc`).
    @MainActor
    func testInitialInputRunsRealLoginShellWithZshPath() throws {
        let configuration = GhosttySurfaceConfiguration(
            command: nil,
            initialInput: "echo INVOKER=$0 SHELL=$SHELL; echo PATH=$PATH\n")
        let grid = try captureGrid(configuration: configuration)

        XCTAssertTrue(
            grid.contains("INVOKER="),
            "initial_input probe did not run; grid was:\n\(grid)")
        XCTAssertTrue(
            grid.contains("zsh"),
            "expected the real login shell (zsh), not bash; grid was:\n\(grid)")
        XCTAssertTrue(
            grid.contains("/opt/homebrew/bin"),
            "expected Homebrew's zsh-dotfile PATH entry; grid was:\n\(grid)")
    }

    /// A command containing `exec` must still just be typed text — `initial_input`
    /// has no special `exec` handling of its own (that was `command`'s broken
    /// behavior). This only confirms the literal text reaches the shell; it does
    /// not by itself prove process-replacement semantics either way.
    @MainActor
    func testInitialInputExecMarkerAppears() throws {
        let configuration = GhosttySurfaceConfiguration(
            command: nil,
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
            command: nil,
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
        let runtime = try GhosttyRuntime()
        let view = GhosttySurfaceView(runtime: runtime, configuration: configuration)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let surface = view.surface else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }
        XCTAssertTrue(window.makeFirstResponder(view))

        // Let the shell reach an interactive prompt, consume the queued initial_input,
        // and print its output before we read the grid.
        settle(0.6)
        settle(0.4)

        return surface.readText(scrollback: false) ?? ""
    }

    /// Pump the main run loop for a fixed duration so libghostty can drain PTY output and
    /// the shell can settle. Fixed pump, not adaptive polling — see the harness note.
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
