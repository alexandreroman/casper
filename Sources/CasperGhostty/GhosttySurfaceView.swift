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
            pushContentScale()
            pushSize()
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

    func debugSendText(_ text: String) {
        surface?.sendText(text)
    }

    func debugColumnsRows() -> (Int, Int) {
        surface?.surfaceSize() ?? (0, 0)
    }
    #endif

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushContentScale()
        pushSize()
        pushDisplayID()
    }

    private func pushSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds).size
        surface.setSize(
            widthPixels: UInt32(max(0, backing.width)),
            heightPixels: UInt32(max(0, backing.height)))
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
        _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
        // Let the input system produce committed text → insertText(_:).
        interpretKeyEvents([event])
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
        surface?.sendText(text)
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
