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

    /// The `NSEvent.Phase`→libghostty-momentum mapping `scrollWheel` packs into the opaque
    /// `ghostty_input_scroll_mods_t`, whose real layout is a packed i32: bit 0 is the precision
    /// flag, bits 1–3 the momentum. An unknown phase (including the empty set) reports NONE.
    @MainActor
    func testMomentumPhaseMapsAndPacksIntoScrollMods() {
        XCTAssertEqual(
            GhosttySurfaceView.ghosttyMomentum(for: .began).rawValue, GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        XCTAssertEqual(
            GhosttySurfaceView.ghosttyMomentum(for: .changed).rawValue, GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        XCTAssertEqual(
            GhosttySurfaceView.ghosttyMomentum(for: .ended).rawValue, GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        XCTAssertEqual(
            GhosttySurfaceView.ghosttyMomentum(for: []).rawValue, GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)

        // A trackpad scroll sets the precision bit and shifts the momentum clear of it, so
        // both survive in the same int.
        let mods = 1 | Int32(GhosttySurfaceView.ghosttyMomentum(for: .ended).rawValue) << 1
        XCTAssertEqual(mods & 1, 1, "the precision bit must stay in bit 0")
        XCTAssertEqual((mods >> 1) & 0b111, Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue))
    }

    /// Guards the fix where the bare key event left `unshifted_codepoint` at 0, which silently
    /// disabled libghostty's control encoding so Ctrl-C/Ctrl-D produced no output.
    func testBareKeyEventCarriesUnshiftedCodepointForControlEncoding() {
        let event = makeControlCKeyEvent()
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.unshifted_codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertNil(key.text)
    }

    /// A bare Control-letter combo is encoded by libghostty from the *physical* keycode, so the
    /// keycode is normalized to the letter's QWERTY position: on AZERTY, 'a' is struck at the
    /// QWERTY 'Q' position (keycode 12) and the raw keycode makes Ctrl-A wipe the line instead of
    /// moving to its start. The produced letter still drives `unshifted_codepoint`.
    func testControlLetterComboNormalizesKeycodeToItsQwertyPosition() {
        let event = makeControlAKeyEvent(keyCode: 12)  // 'a' on an AZERTY keyboard
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.keycode, 0, "Ctrl-A must encode from the QWERTY 'A' position (kVK_ANSI_A)")
        XCTAssertEqual(key.unshifted_codepoint, UInt32(UnicodeScalar("a").value))
    }

    /// Guards the fix where building a key event for a modifier press raised
    /// `NSInternalInconsistencyException` — AppKit rejects `charactersIgnoringModifiers` on a
    /// `.flagsChanged` event — and the throw unwound before `sendKey`, so no modifier state ever
    /// reached libghostty. A modifier transition must encode as its own keycode with no base
    /// codepoint and no text, exactly like Ghostty's reference `keyAction`.
    func testControlPressFlagsChangedEventEncodesWithoutRaising() {
        let event = makeControlFlagsChangedEvent(modifierFlags: [.control])
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
        XCTAssertEqual(key.unshifted_codepoint, 0)
        XCTAssertEqual(key.keycode, UInt32(controlKeyCode))
        XCTAssertNil(key.text)
        XCTAssertNotEqual(key.mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }

    /// The release half of `testControlPressFlagsChangedEventEncodesWithoutRaising`: letting
    /// Control go is also a `.flagsChanged` event, and it must encode with the Ctrl bit cleared
    /// rather than raise on the character read.
    func testControlReleaseFlagsChangedEventEncodesWithoutRaising() {
        let event = makeControlFlagsChangedEvent(modifierFlags: [])
        let key = ghosttyKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
        XCTAssertEqual(key.unshifted_codepoint, 0)
        XCTAssertEqual(key.keycode, UInt32(controlKeyCode))
        XCTAssertNil(key.text)
        XCTAssertEqual(key.mods.rawValue, GHOSTTY_MODS_NONE.rawValue)
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

/// Build a synthetic Ctrl-A keyDown struck at `keyCode`, the way a real keyboard reports it:
/// `characters` is the control scalar, `charactersIgnoringModifiers` the produced letter. The
/// keycode is the physical position, which differs between layouts for the same letter.
private func makeControlAKeyEvent(keyCode: UInt16) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{01}",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: keyCode
    )!
}

/// Virtual keycode of the left Control key (kVK_Control), the physical key whose transitions
/// AppKit reports as `.flagsChanged`.
private let controlKeyCode: UInt16 = 0x3B

/// Build a synthetic `.flagsChanged` event for the Control key: `modifierFlags: [.control]` is the
/// press, `[]` the release. `NSEvent.keyEvent(with:...)` accepts the type and requires character
/// strings, but AppKit raises when they are *read* back off a non-key event — which is exactly the
/// behaviour these tests pin down, so the empty strings passed here are never observable.
private func makeControlFlagsChangedEvent(modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .flagsChanged,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: controlKeyCode
    )!
}
