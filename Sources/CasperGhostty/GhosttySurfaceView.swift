import AppKit
import CasperCore
import GhosttyKit

/// An `NSView` that libghostty renders one terminal surface into. Forwards
/// keyboard/mouse/text events and geometry changes to the surface.
///
/// libghostty owns the Metal layer and render thread: this view never creates a
/// `CAMetalLayer` and never calls `draw()` itself. It only passes `self` as the
/// `nsview` in the surface configuration and lets libghostty attach its own layer.
public final class GhosttySurfaceView: NSView, @MainActor NSTextInputClient {
    private let runtime: GhosttyRuntime
    private let configuration: GhosttySurfaceConfiguration
    private let surfaceID: UUID
    var onFocus: (UUID) -> Void
    // Fired once this view is live in a window (see `viewDidMoveToWindow`). Lets
    // the host claim AppKit first responder for the surface it already considers
    // focused, which a SwiftUI `.onAppear` cannot do because the view may not yet
    // be attached to a window when `.onAppear` runs.
    var onAttach: (UUID) -> Void
    var onClose: (UUID) -> Void
    // Internal (not private): the clipboard callback trampolines in
    // `GhosttyRuntime` recover this view from libghostty's userdata and need
    // its surface.
    var surface: GhosttySurface?

    // Collects the text the input system commits during a single `keyDown`, so
    // that text can ride on the key event (`key.text`) instead of going through
    // the separate `ghostty_surface_text` path. It is non-nil only for the span
    // of a `keyDown`; `insertText` appends to it when set, else sends directly.
    private var keyTextAccumulator: [String]?

    public init(
        runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration,
        surfaceID: UUID = UUID(), onFocus: @escaping (UUID) -> Void = { _ in },
        onAttach: @escaping (UUID) -> Void = { _ in },
        onClose: @escaping (UUID) -> Void = { _ in }
    ) {
        self.surfaceID = surfaceID
        self.onFocus = onFocus
        self.onAttach = onAttach
        self.onClose = onClose
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: .zero)
        // libghostty attaches its own CAMetalLayer to this view.
        wantsLayer = true
        postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    // A click on an unfocused terminal must both focus this view AND arrive as a
    // `mouseDown`, so a drag-selection starts at the clicked point instead of the
    // click being swallowed just to activate the view.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Create the surface once the view is in a window (so `self` is a valid,
    // sized host). Idempotent.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Create the surface on first attach only; a later re-parent keeps it.
        if surface == nil {
            let nsview = Unmanaged.passUnretained(self).toOpaque()
            do {
                // userdata == nsview: libghostty hands this pointer back verbatim to
                // the clipboard callbacks, letting them recover this view.
                surface = try GhosttySurface(
                    runtime: runtime, configuration: configuration, nsview: nsview, userdata: nsview)
                syncLayerContentsScale()
                pushContentScale()
                pushSize()
                pushDisplayID()
            } catch {
                CasperLog.ghostty.error("surface creation failed: \(String(describing: error), privacy: .public)")
            }
        }
        // Now that the view is live in a window, let the host claim first responder
        // for it if the model already considers this surface focused. Runs on every
        // attach (not just the first), so a workspace switch that re-mounts this view
        // still lands keyboard focus on the terminal.
        onAttach(surfaceID)
    }

    // MARK: Debug accessors (compiled only into debug builds)

    #if DEBUG
    public var debugHasSurface: Bool { surface != nil }

    public func debugReadText(scrollback: Bool) -> String? {
        surface?.readText(scrollback: scrollback)
    }

    public func debugSendText(_ text: String, submit: Bool) {
        if !text.isEmpty { surface?.sendText(text) }
        guard submit, let surface else { return }
        _ = surface.sendKey(ghosttyKeyEvent(keycode: ghosttyReturnKeyCode, action: GHOSTTY_ACTION_PRESS))
        _ = surface.sendKey(ghosttyKeyEvent(keycode: ghosttyReturnKeyCode, action: GHOSTTY_ACTION_RELEASE))
    }

    // Inject `text` as genuine per-character key events (press + release) through
    // the key path, unlike `debugSendText` which uses the committed-text/paste
    // path. Each character is sent as its physical key with the right modifiers,
    // reproducing real keyboard typing. Unsupported characters are skipped.
    public func debugSendKeys(_ text: String) {
        guard let surface else { return }
        for character in text {
            guard let key = ghosttyInjectedKey(for: character) else {
                CasperLog.debug.debug(
                    "send-keys: skipping unmapped character \(String(character), privacy: .public)")
                continue
            }
            let mods = key.needsShift
                ? ghostty_input_mods_e(GHOSTTY_MODS_SHIFT.rawValue)
                : ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
            // The press carries the committed text; the release carries none, as a
            // real key-up does. `text` must outlive the send, so keep the C buffer
            // alive across `sendKey` with `withCString`.
            String(character).withCString { textPtr in
                let press = ghosttyKeyEvent(
                    keycode: key.keycode, action: GHOSTTY_ACTION_PRESS, mods: mods,
                    text: textPtr, unshiftedCodepoint: key.unshiftedCodepoint)
                _ = surface.sendKey(press)
            }
            let release = ghosttyKeyEvent(
                keycode: key.keycode, action: GHOSTTY_ACTION_RELEASE, mods: mods,
                text: nil, unshiftedCodepoint: key.unshiftedCodepoint)
            _ = surface.sendKey(release)
        }
    }

    // Inject `character` as a real key event (press + release) with the given
    // modifier names, through the bare-event path `performKeyEquivalent` uses.
    public func debugSendKey(_ character: String, mods names: [String]) {
        guard let surface, let ch = character.first else { return }
        guard let key = ghosttyInjectedKey(for: ch) else {
            CasperLog.debug.debug(
                "send-key: skipping unmapped character \(character, privacy: .public)")
            return
        }
        let mods = ghosttyModsFromNames(names)
        // Decide from the computed bitmask, not the raw name strings: `mods`
        // already lowercases names, so checking the strings here could disagree
        // with it (e.g. "CTRL" would set the CTRL bit but slip past a case-
        // sensitive string check). Control/command combos must not carry text.
        let carriesControl = (mods.rawValue & (GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)) != 0
        _ = character.withCString { textPtr in
            surface.sendKey(ghosttyKeyEvent(
                keycode: key.keycode, action: GHOSTTY_ACTION_PRESS, mods: mods,
                text: carriesControl ? nil : textPtr,
                unshiftedCodepoint: key.unshiftedCodepoint))
        }
        _ = surface.sendKey(ghosttyKeyEvent(
            keycode: key.keycode, action: GHOSTTY_ACTION_RELEASE, mods: mods,
            text: nil, unshiftedCodepoint: key.unshiftedCodepoint))
    }

    // Trigger a libghostty keybinding action directly by name, bypassing key-event
    // translation. Used to exercise bindings (e.g. clipboard) that injected ⌘ key
    // events cannot reliably reach in an automated/headless session.
    public func debugSendAction(_ name: String) { surface?.bindingAction(name) }

    /// Inject a mouse position (libghostty top-left coordinates) straight into the
    /// surface, bypassing AppKit event delivery. Used by the `mouse-move` debug
    /// verb to exercise libghostty's mouse-shape emission in headless tests.
    public func debugMouseMove(x: Double, y: Double) {
        surface?.sendMousePos(x: x, y: y, mods: ghosttyMods(from: []))
    }

    // Combine libghostty's surface readback with this view's own AppKit metrics,
    // so the debug channel can pinpoint content-scale double-counting.
    public func debugGeometry() -> DebugSurfaceGeometry {
        guard let surface else {
            return DebugSurfaceGeometry(
                columns: 0, rows: 0, widthPixels: 0, heightPixels: 0,
                cellWidthPixels: 0, cellHeightPixels: 0,
                boundsWidth: 0, boundsHeight: 0, backingWidth: 0, backingHeight: 0,
                contentScaleX: 0, contentScaleY: 0, backingScaleFactor: 0)
        }
        let g = surface.geometry()
        let backingBounds = convertToBacking(bounds).size
        let contentScale = convertToBacking(NSSize(width: 1, height: 1))
        return DebugSurfaceGeometry(
            columns: g.columns, rows: g.rows,
            widthPixels: g.widthPixels, heightPixels: g.heightPixels,
            cellWidthPixels: g.cellWidthPixels, cellHeightPixels: g.cellHeightPixels,
            boundsWidth: Double(bounds.size.width), boundsHeight: Double(bounds.size.height),
            backingWidth: Double(backingBounds.width), backingHeight: Double(backingBounds.height),
            contentScaleX: Double(contentScale.width), contentScaleY: Double(contentScale.height),
            backingScaleFactor: Double(window?.backingScaleFactor ?? 0))
    }
    #endif

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerContentsScale()
        pushContentScale()
        pushSize()
        pushDisplayID()
    }

    // Keep libghostty's Metal layer at the window's backing scale so Core Animation
    // does not upscale the already-native-resolution render during compositing.
    private func syncLayerContentsScale() {
        guard let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
    }

    private func pushSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds).size
        // Never feed a non-finite value into UInt32(_:), which traps on NaN/inf.
        let width = backing.width.isFinite ? max(0, backing.width) : 0
        let height = backing.height.isFinite ? max(0, backing.height) : 0
        surface.setSize(widthPixels: UInt32(width), heightPixels: UInt32(height))
    }

    private func pushContentScale() {
        guard let surface else { return }
        let backing = convertToBacking(NSSize(width: 1, height: 1))
        surface.setContentScale(x: Double(backing.width), y: Double(backing.height))
    }

    // Drive libghostty's internal display link at the screen's refresh rate.
    private func pushDisplayID() {
        guard let surface, let screen = window?.screen else { return }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let id = number?.uint32Value else { return }
        ghostty_surface_set_display_id(surface.surface, id)
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        onFocus(surfaceID)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    /// Ask the host to close this surface. Invoked by libghostty's
    /// `close_surface_cb` (via the runtime) when the child process exits
    /// (Ctrl-D / `exit`) or a close-surface request arrives.
    func requestClose() { onClose(surfaceID) }

    // MARK: Menu actions

    // Edit/View menu items built by `buildMainMenu()` carry no `target`, so
    // AppKit dispatches them up the responder chain; these fire whenever this
    // view is the focused (first-responder) surface. `copy(_:)`/`paste(_:)` are
    // plain selectors AppKit's Edit menu convention expects (not declared by
    // `NSResponder`); `selectAll(_:)` overrides the one `NSResponder` does
    // declare. The font-size selectors are custom, referenced directly by
    // `buildMainMenu()`.

    @objc func copy(_ sender: Any?) {
        surface?.bindingAction("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        surface?.bindingAction("paste_from_clipboard")
    }

    public override func selectAll(_ sender: Any?) {
        surface?.bindingAction("select_all")
    }

    @objc func increaseFontSize(_ sender: Any?) {
        surface?.bindingAction("increase_font_size:1")
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        surface?.bindingAction("decrease_font_size:1")
    }

    @objc func resetFontSize(_ sender: Any?) {
        surface?.bindingAction("reset_font_size")
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        // Ask libghostty how Option should behave for this event, per the loaded
        // `macos-option-as-alt` config, and build the event Cocoa's text system
        // should see accordingly (see `ghosttyTranslationEvent`).
        let rawMods = ghosttyMods(from: event.modifierFlags)
        let translationMods = ghostty_surface_key_translation_mods(surface.surface, rawMods)
        let translationEvent = ghosttyTranslationEvent(for: event, translationMods: translationMods)

        // Drive the input system first so `insertText` can accumulate any committed
        // text; libghostty wants that text attached to the key event, not sent via
        // the separate `ghostty_surface_text` path (which renders the cursor wrong).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])

        // Whether Option was left in place for the event Cocoa just composed from: if
        // so, Option was "consumed" producing that committed text (e.g. an accented
        // character), and libghostty must not also re-encode it as a Meta escape. This
        // only matters for the composed-text path below: for the bare (text-less)
        // paths — Option+arrows, Option+Delete, bare control characters — the pinned
        // libghostty uses `consumed_mods` to drive its own keycode encoding, so it must
        // stay NONE there or Option's Alt/Meta sequence gets silently dropped.
        let consumedMods: ghostty_input_mods_e = translationEvent.modifierFlags.contains(.option)
            ? ghostty_input_mods_e(GHOSTTY_MODS_ALT.rawValue)
            : ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)

        guard let committed = keyTextAccumulator, !committed.isEmpty else {
            // No committed text (arrows, Return, Backspace, Ctrl-combos): send the bare
            // key event and let the keycode drive libghostty's own encoding. Omit
            // `consumedMods` (defaults to NONE) so Option+arrows/Delete keep their
            // Alt/Meta encoding.
            _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
            return
        }
        for text in committed {
            guard ghosttyTextRidesOnKeyEvent(text) else {
                // A bare control character (Ctrl-C, Ctrl-D): send the bare key event
                // and let the keycode drive libghostty's own control-char encoding,
                // exactly as the empty-accumulator fallback above does — same reason
                // `consumedMods` is omitted here.
                _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
                continue
            }
            // `key.text` must outlive the send, so keep the C buffer alive across
            // `sendKey` with `withCString`. `consumedMods` is passed here because this
            // is the composed-text path: Option was consumed to produce `text`.
            text.withCString { textPtr in
                _ = surface.sendKey(
                    ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS, text: textPtr, consumedMods: consumedMods))
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_RELEASE))
    }

    public override func flagsChanged(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let surface else { return false }
        // performKeyEquivalent fires for every key-down. Only Command combos need it:
        // macOS never routes ⌘ combos to keyDown. Control/Option/plain keys and
        // navigation keys must fall through to keyDown, which owns IME/dead-key
        // composition and control-character encoding.
        guard event.modifierFlags.contains(.command) else { return false }
        // Only when focused, so ⌘Q/⌘Tab and menu equivalents still work when we're not.
        guard window?.firstResponder === self else { return false }
        // ⌘ combos carry no committed text; return libghostty's consumed flag so unbound
        // ⌘ combos fall through to the menu / system.
        return surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
    }

    // MARK: Mouse

    // libghostty's core tracks the pointer from a continuous stream of position
    // updates and detects multi-click (double = word, triple = line) itself using
    // that stream's timing and position. Without a tracking area,
    // `mouseMoved`/`mouseEntered`/`mouseExited` never fire, so the core's position
    // is refreshed only during a drag and a fresh click lands at a stale cell. One
    // tracking area over the whole visible rect restores the stream, matching
    // upstream Ghostty.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    public override func mouseDown(with event: NSEvent) {
        // Report the position before the press so the selection anchors on the exact
        // clicked cell even when no `mouseMoved` preceded this click (a cold click into
        // an unfocused window). Upstream relies on the tracking stream alone; this
        // pre-press position is a small, safe guard for the first-mouse case.
        mousePos(event)
        mouseButton(event, GHOSTTY_MOUSE_LEFT, down: true)
    }

    public override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_LEFT, down: false) }

    public override func rightMouseDown(with event: NSEvent) {
        mousePos(event)  // See `mouseDown`: anchor on the exact cell.
        mouseButton(event, GHOSTTY_MOUSE_RIGHT, down: true)
    }

    public override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RIGHT, down: false) }

    public override func otherMouseDown(with event: NSEvent) {
        mousePos(event)  // See `mouseDown`: anchor on the exact cell.
        mouseButton(event, Self.ghosttyButton(for: event.buttonNumber), down: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        mouseButton(event, Self.ghosttyButton(for: event.buttonNumber), down: false)
    }

    public override func mouseMoved(with event: NSEvent) { mousePos(event) }
    public override func mouseDragged(with event: NSEvent) { mousePos(event) }
    public override func rightMouseDragged(with event: NSEvent) { mousePos(event) }
    public override func otherMouseDragged(with event: NSEvent) { mousePos(event) }

    public override func mouseEntered(with event: NSEvent) {
        // NSCursor is a stack the system resets when the pointer crosses view
        // boundaries; re-apply the shape libghostty last requested.
        lastCursor.set()
        mousePos(event)
    }

    public override func mouseExited(with event: NSEvent) {
        // Upstream: while a button is held, a drag past the edge must keep selecting,
        // so don't report the exit. Otherwise report an off-surface position so the
        // core clears its hover state.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        // Restore the default arrow: the terminal's I-beam must not leak onto sibling
        // chrome that defines no cursor rect of its own (matches upstream Ghostty).
        NSCursor.arrow.set()
        surface?.sendMousePos(x: -1, y: -1, mods: ghosttyMods(from: event.modifierFlags))
    }

    public override func cursorUpdate(with event: NSEvent) {
        // `cursorUpdate` is AppKit's own cursor-management hook, invoked as the pointer
        // moves over this tracking area. Setting the cursor here wins over AppKit's
        // default cursor-rect reset (which forces the arrow) that was clobbering the
        // async `.set()` from `setCursorShape`, so libghostty's I-beam finally sticks.
        lastCursor.set()
    }

    public override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        // Precise (trackpad / high-resolution) deltas arrive in points at roughly half
        // the magnitude of line-based wheel deltas; double them so trackpad and wheel
        // scrolling feel consistent, matching upstream Ghostty.
        if event.hasPreciseScrollingDeltas {
            deltaX *= 2
            deltaY *= 2
        }
        // Momentum/precision packing into `ghostty_input_scroll_mods_t` (an int whose
        // bit layout the pinned header does not document) is left unencoded: passing 0
        // omits the momentum path rather than guessing the layout. The ×2 precise-delta
        // scaling above is the fix that matters for scroll feel.
        surface.sendMouseScroll(deltaX: deltaX, deltaY: deltaY, mods: ghostty_input_scroll_mods_t(0))
    }

    /// Map an `NSEvent.buttonNumber` to libghostty's mouse button. 0→LEFT, 1→RIGHT,
    /// 2→MIDDLE, 3→FOUR, 4→FIVE; anything else is reported as UNKNOWN. Pure and
    /// static so it is unit-testable without a running app.
    static func ghosttyButton(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
        switch buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    private func mouseButton(_ event: NSEvent, _ button: ghostty_input_mouse_button_e, down: Bool) {
        guard let surface else { return }
        let state = down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        surface.sendMouseButton(
            state: state, button: button, mods: ghosttyMods(from: event.modifierFlags))
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // libghostty expects top-left origin; flip Y.
        surface.sendMousePos(
            x: Double(point.x), y: Double(bounds.height - point.y),
            mods: ghosttyMods(from: event.modifierFlags))
    }

    // MARK: Cursor

    // The terminal's resting pointer shape is the I-beam (text), matching upstream
    // Ghostty's default. libghostty only emits MOUSE_SHAPE to CHANGE it (pointer over
    // a link, resize handles, or the arrow in mouse-reporting mode), never for the
    // resting text shape — so the I-beam must be our baseline, applied via
    // `cursorUpdate`/`mouseEntered`, not awaited as an action.
    private var lastCursor: NSCursor = .iBeam

    /// Pure mapping from a libghostty mouse shape to the matching `NSCursor`.
    /// Returns nil for shapes AppKit has no cursor for, so the caller leaves the
    /// current cursor unchanged (upstream's `default: return`). Static so it is
    /// unit-testable without a running app.
    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor? {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: return .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_CELL: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_COPY: return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS: return .dragLink
        case GHOSTTY_MOUSE_SHAPE_NO_DROP, GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeUpDown
        // AppKit has no dedicated cursor for the diagonal resizes, all-scroll, zoom,
        // progress/wait, help, or move shapes: leave the current cursor as-is.
        default: return nil
        }
    }

    /// Apply a libghostty-requested mouse shape. Unmapped shapes leave the cursor
    /// unchanged. Called from the action trampoline on the main thread.
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        guard let cursor = Self.cursor(for: shape) else { return }
        lastCursor = cursor
        cursor.set()
    }

    /// Show or hide the mouse cursor. libghostty requests hiding while the user
    /// types; `setHiddenUntilMouseMoves` auto-restores it on the next movement.
    func setCursorVisibility(_ visible: Bool) {
        NSCursor.setHiddenUntilMouseMoves(!visible)
    }

    // MARK: NSTextInputClient (committed/IME text)

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Inside a `keyDown`, hand the text to the accumulator so it can ride on the
        // key event. Outside one (paste, IME commit), send it as bulk text.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else {
            surface?.sendText(text)
        }
    }

    public func hasMarkedText() -> Bool { false }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    public func unmarkText() {}
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    public func firstRect(
        forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect { .zero }
    public override func doCommand(by selector: Selector) {}
}

extension GhosttySurfaceView: NSMenuItemValidation {
    // The Edit/View menu items built by `buildMainMenu()` all target this view
    // via the responder chain; enable them only while it hosts a live surface.
    // Copy additionally requires a selection to copy.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let surface else { return false }
        if menuItem.action == #selector(copy(_:)) {
            return surface.hasSelection()
        }
        return true
    }
}
