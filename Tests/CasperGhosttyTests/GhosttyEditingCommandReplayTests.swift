import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// End-to-end guard that Control-letter shell/readline shortcuts reach the shell
/// instead of being swallowed by Cocoa's key-binding table. Cocoa resolves Ctrl-A to
/// the `moveToBeginningOfParagraph:` editing selector via `interpretKeyEvents`; the
/// view must discard that Cocoa command and forward the raw keystroke so the shell's
/// own line editor (zle/readline) moves the cursor.
///
/// Uses a real `GhosttyRuntime` + real (offscreen) `NSWindow` so `interpretKeyEvents`
/// runs against a live input context and a real PTY-backed shell — the `.forTesting()`
/// runtime never creates a surface.
final class GhosttyEditingCommandReplayTests: XCTestCase {
    /// Ctrl-A struck on a QWERTY keyboard: 'a' is at physical keycode 0. Baseline
    /// non-regression check that the fix leaves the common layout working.
    @MainActor
    func testControlAMovesToLineStartOnQwerty() throws {
        try assertControlAMovesToLineStart(keyCode: 0)
    }

    /// Ctrl-A struck on an AZERTY keyboard: 'a' is at physical keycode 12 (the QWERTY
    /// 'Q' position). The pinned libghostty mis-encodes the bare Control-combo for that
    /// physical position — without the keycode normalization it wipes the line instead
    /// of moving to its start (the user's live-reported bug). Reproduces that exact case.
    @MainActor
    func testControlAMovesToLineStartOnAzerty() throws {
        try assertControlAMovesToLineStart(keyCode: 12)
    }

    /// Seed "abc", strike Ctrl-A (physical `keyCode`, base letter 'a'), insert "Z", and
    /// assert the marker landed at the line start ("Zabc") — proving the keystroke moved
    /// the shell cursor rather than being mis-encoded (which wipes the line to "Z").
    @MainActor
    private func assertControlAMovesToLineStart(keyCode: UInt16) throws {
        let runtime = try GhosttyRuntime()
        let view = GhosttySurfaceView(runtime: runtime, configuration: GhosttySurfaceConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        // Surface creation can transiently return null and retry; poll until it lands.
        // When libghostty simply cannot produce a surface (a documented environmental
        // flakiness — see the `e2e-surface-creation-flakiness` memory note), the test's
        // precondition is unmet, so skip rather than report a false failure.
        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let surface = view.surface else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }
        XCTAssertTrue(window.makeFirstResponder(view))

        // Let the shell reach an interactive prompt before typing.
        settle(0.6)

        // Seed a known line (goes to the shell's stdin); the cursor ends at the end of "abc".
        surface.sendText("abc")
        settle(0.4)

        // Ctrl-A resolves to moveToBeginningOfParagraph:. Forwarded raw with a correctly
        // encoded keycode, the shell moves the cursor to the start of the line.
        view.keyDown(with: controlKeyEvent(character: "\u{01}", base: "a", keyCode: keyCode))
        settle(0.4)

        // Insert a marker at the cursor: "Zabc" proves Ctrl-A reached the shell and moved
        // to line start; "Z" alone (the line wiped) is the mis-encoded-keycode bug.
        surface.sendText("Z")
        settle(0.4)

        let grid = surface.readText(scrollback: false) ?? ""
        XCTAssertTrue(
            grid.contains("Zabc"),
            "Ctrl-A (keyCode \(keyCode)) did not move to line start; grid was:\n\(grid)")
    }

    /// A bare control character that reaches `insertText` outside a `keyDown` span (a
    /// Control-combo whose `insertText` dispatched late) must never be forwarded to the
    /// bulk-text path, where `ghostty_surface_text` would mis-encode it into a visible
    /// "^A"-style artifact. Deterministic and surfaceless: `keyTextAccumulator` is nil
    /// on a fresh view, so `insertText` takes the outside-`keyDown` branch directly.
    @MainActor
    func testControlCharacterOutsideKeyDownIsNotForwardedAsBulkText() {
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())

        view.insertText("\u{01}", replacementRange: NSRange(location: NSNotFound, length: 0))  // Ctrl-A
        XCTAssertNil(view.debugLastBulkText, "a bare control character must not reach ghostty_surface_text")

        view.insertText("\u{0B}", replacementRange: NSRange(location: NSNotFound, length: 0))  // Ctrl-K
        XCTAssertNil(view.debugLastBulkText, "a bare control character must not reach ghostty_surface_text")

        // Genuine printable text (an IME/dictation commit) must still be forwarded.
        view.insertText("héllo", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.debugLastBulkText, "héllo")
    }

    /// Pump the main run loop for a fixed duration so libghostty can drain PTY output
    /// and the shell can settle. A stability-polling loop was flaky here; a fixed pump
    /// is enough.
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Build a synthetic Control-<letter> keyDown the way a real keyboard reports it:
    /// `characters` is the control scalar, `charactersIgnoringModifiers` the base letter.
    private func controlKeyEvent(character: String, base: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: character,
            charactersIgnoringModifiers: base, isARepeat: false, keyCode: keyCode)!
    }
}
