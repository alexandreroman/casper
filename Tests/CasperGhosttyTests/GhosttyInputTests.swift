import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

final class GhosttyInputTests: XCTestCase {
    func testNoModifiersIsEmpty() {
        XCTAssertEqual(ghosttyMods(from: []).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testCommandShiftMapsToSuperShift() {
        let mods = ghosttyMods(from: [.command, .shift])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }

    func testControlOptionMapsToCtrlAlt() {
        let mods = ghosttyMods(from: [.control, .option])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
    }

    func testControlCharactersDoNotRideOnKeyEvent() {
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\u{03}"))  // Ctrl-C
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\u{04}"))  // Ctrl-D
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\r"))  // 0x0D
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent("\t"))  // 0x09
    }

    func testPrintableTextRidesOnKeyEvent() {
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent("a"))
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent(" "))  // space, 0x20
        XCTAssertTrue(ghosttyTextRidesOnKeyEvent("é"))
    }

    func testEmptyTextDoesNotRideOnKeyEvent() {
        XCTAssertFalse(ghosttyTextRidesOnKeyEvent(""))
    }

    /// A click on an unfocused terminal must be delivered as a `mouseDown` (not swallowed just to
    /// activate the view), so a drag-selection starts at the clicked point. This checks the pure
    /// return value only; it needs no real OS focus.
    @MainActor
    func testAcceptsFirstMouseSoUnfocusedClickStartsSelection() {
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    /// Without a tracking area the core never receives `mouseMoved`/`mouseEntered`, so a fresh
    /// click lands at a stale position. The view must install exactly one tracking area that
    /// covers moves and enter/exit. This is headlessly observable — no real OS focus needed.
    @MainActor
    func testUpdateTrackingAreasInstallsOneMoveTrackingArea() {
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        let options = view.trackingAreas[0].options
        XCTAssertTrue(options.contains(.mouseMoved))
        XCTAssertTrue(options.contains(.mouseEnteredAndExited))
        // Called again (as AppKit does on every geometry change), it must not accumulate areas.
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
    }

    /// The pure shape→cursor mapping libghostty's `MOUSE_SHAPE` action drives: text cells get the
    /// I-beam, the default shape the arrow, and a couple of representative others map through.
    @MainActor
    func testCursorMappingCoversRepresentativeShapes() {
        XCTAssertEqual(GhosttySurfaceView.cursor(for: GHOSTTY_MOUSE_SHAPE_TEXT), .iBeam)
        XCTAssertEqual(GhosttySurfaceView.cursor(for: GHOSTTY_MOUSE_SHAPE_DEFAULT), .arrow)
        XCTAssertEqual(GhosttySurfaceView.cursor(for: GHOSTTY_MOUSE_SHAPE_POINTER), .pointingHand)
        XCTAssertEqual(GhosttySurfaceView.cursor(for: GHOSTTY_MOUSE_SHAPE_CROSSHAIR), .crosshair)
        // A shape AppKit has no cursor for leaves the caller's cursor unchanged.
        XCTAssertNil(GhosttySurfaceView.cursor(for: GHOSTTY_MOUSE_SHAPE_PROGRESS))
    }

    /// The `NSEvent.buttonNumber`→libghostty-button mapping used by the middle/extra mouse buttons.
    @MainActor
    func testButtonNumberMapsToGhosttyButton() {
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 0).rawValue, GHOSTTY_MOUSE_LEFT.rawValue)
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 1).rawValue, GHOSTTY_MOUSE_RIGHT.rawValue)
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 2).rawValue, GHOSTTY_MOUSE_MIDDLE.rawValue)
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 3).rawValue, GHOSTTY_MOUSE_FOUR.rawValue)
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 4).rawValue, GHOSTTY_MOUSE_FIVE.rawValue)
        XCTAssertEqual(GhosttySurfaceView.ghosttyButton(for: 9).rawValue, GHOSTTY_MOUSE_UNKNOWN.rawValue)
    }

    /// Guards the fix where the bare key event left `unshifted_codepoint` at 0, which silently
    /// disabled libghostty's control encoding so Ctrl-C/Ctrl-D produced no output.
    func testBareKeyEventCarriesUnshiftedCodepointForControlEncoding() {
        let event = makeControlCKeyEvent()
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.unshifted_codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertNil(key.text)
    }
}

/// Build a synthetic Ctrl-C keyDown. A real Control press remaps `characters` to the control
/// scalar (U+0003) while `charactersIgnoringModifiers` stays the base key ("c"), which is what
/// `unshifted_codepoint` must be derived from.
private func makeControlCKeyEvent() -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{03}",
        charactersIgnoringModifiers: "c",
        isARepeat: false,
        keyCode: 8  // kVK_ANSI_C
    )!
}
