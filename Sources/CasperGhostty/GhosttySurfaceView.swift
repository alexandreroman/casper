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
    private var surface: GhosttySurface?

    // Collects the text the input system commits during a single `keyDown`, so
    // that text can ride on the key event (`key.text`) instead of going through
    // the separate `ghostty_surface_text` path. It is non-nil only for the span
    // of a `keyDown`; `insertText` appends to it when set, else sends directly.
    private var keyTextAccumulator: [String]?

    public init(runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration) {
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

    // Create the surface once the view is in a window (so `self` is a valid,
    // sized host). Idempotent.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard surface == nil, window != nil else { return }
        let nsview = Unmanaged.passUnretained(self).toOpaque()
        do {
            surface = try GhosttySurface(
                runtime: runtime, configuration: configuration, nsview: nsview)
            syncLayerContentsScale()
            pushContentScale()
            pushSize()
            pushDisplayID()
        } catch {
            CasperLog.ghostty.error("surface creation failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Debug accessors (compiled only into debug builds)

    #if DEBUG
    var debugHasSurface: Bool { surface != nil }

    func debugReadText(scrollback: Bool) -> String? {
        surface?.readText(scrollback: scrollback)
    }

    func debugSendText(_ text: String, submit: Bool) {
        if !text.isEmpty { surface?.sendText(text) }
        guard submit, let surface else { return }
        _ = surface.sendKey(ghosttyKeyEvent(keycode: ghosttyReturnKeyCode, action: GHOSTTY_ACTION_PRESS))
        _ = surface.sendKey(ghosttyKeyEvent(keycode: ghosttyReturnKeyCode, action: GHOSTTY_ACTION_RELEASE))
    }

    // Inject `text` as genuine per-character key events (press + release) through
    // the key path, unlike `debugSendText` which uses the committed-text/paste
    // path. Each character is sent as its physical key with the right modifiers,
    // reproducing real keyboard typing. Unsupported characters are skipped.
    func debugSendKeys(_ text: String) {
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

    // Combine libghostty's surface readback with this view's own AppKit metrics,
    // so the debug channel can pinpoint content-scale double-counting.
    func debugGeometry() -> DebugSurfaceGeometry {
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
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        // Drive the input system first so `insertText` can accumulate any committed
        // text; libghostty wants that text attached to the key event, not sent via
        // the separate `ghostty_surface_text` path (which renders the cursor wrong).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        guard let committed = keyTextAccumulator, !committed.isEmpty else {
            // No committed text (arrows, Return, Backspace, Ctrl-combos): send the
            // bare key event and let the keycode drive libghostty's own encoding.
            _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
            return
        }
        for text in committed {
            // `key.text` must outlive the send, so keep the C buffer alive across
            // `sendKey` with `withCString`.
            text.withCString { textPtr in
                _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS, text: textPtr))
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_RELEASE))
    }

    public override func flagsChanged(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) { mouseButton(event, .left, down: true) }
    public override func mouseUp(with event: NSEvent) { mouseButton(event, .left, down: false) }
    public override func rightMouseDown(with event: NSEvent) { mouseButton(event, .right, down: true) }
    public override func rightMouseUp(with event: NSEvent) { mouseButton(event, .right, down: false) }
    public override func mouseMoved(with event: NSEvent) { mousePos(event) }
    public override func mouseDragged(with event: NSEvent) { mousePos(event) }

    public override func scrollWheel(with event: NSEvent) {
        surface?.sendMouseScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            mods: ghostty_input_scroll_mods_t(0))
    }

    private enum Button { case left, right }

    private func mouseButton(_ event: NSEvent, _ button: Button, down: Bool) {
        guard let surface else { return }
        let state = down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        let ghosttyButton = button == .left ? GHOSTTY_MOUSE_LEFT : GHOSTTY_MOUSE_RIGHT
        surface.sendMouseButton(
            state: state, button: ghosttyButton, mods: ghosttyMods(from: event.modifierFlags))
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // libghostty expects top-left origin; flip Y.
        surface.sendMousePos(
            x: Double(point.x), y: Double(bounds.height - point.y),
            mods: ghosttyMods(from: event.modifierFlags))
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
