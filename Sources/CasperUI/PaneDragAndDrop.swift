import AppKit
import CasperCore
import SwiftUI
import UniformTypeIdentifiers

/// AppKit drag SOURCE for a pane's "3-dot" grip, mirroring Ghostty's
/// `SurfaceGrabHandle`/`SurfaceDragSource`. It is layered ABOVE the pane content
/// in a `ZStack`: a real sibling `NSView` hit-tests in front of the Metal
/// terminal view, which a SwiftUI `.draggable` overlay could not (the Metal view
/// would swallow the mouse-down). SwiftUI sizes this view to the grab zone, so
/// the whole `bounds` is the grip — Ghostty drives the cursor the same way, via
/// `cursorUpdate(with:)` over the bounds (open hand, or closed hand while dragging).
final class PaneDragHandleView: NSView, NSDraggingSource {
    private let surfaceID: UUID
    private let label: String
    private let onDragStateChange: (Bool) -> Void

    /// Cursor is over the grip: reveals the three dots. Redraws on change.
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }
    /// A drag is in flight from this grip; swaps the `cursorUpdate` shape from
    /// open to closed hand.
    private var isTracking = false
    private var pressed = false
    /// Where the press landed, in this view's coordinates; the drag arms only once
    /// the cursor travels past `dragSlop` from here.
    private var mouseDownLocation: NSPoint = .zero

    /// Movement past this distance (points) promotes a press into a drag, so a
    /// small jitter while clicking the grip does not start one accidentally.
    private static let dragSlop: CGFloat = 3

    init(surfaceID: UUID, label: String, onDragStateChange: @escaping (Bool) -> Void) {
        self.surfaceID = surfaceID
        self.label = label
        self.onDragStateChange = onDragStateChange
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left origin, matching SwiftUI, so the grip sits at `y == 0`.
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor

    /// Open hand at rest, closed hand while dragging — applied via AppKit's
    /// `cursorUpdate` (the mechanism `GhosttySurfaceView` uses for its I-beam),
    /// which is dispatched to the view under the pointer on every move. This is
    /// reliable regardless of where the pointer enters from (unlike a cursor rect,
    /// which is not re-applied when entering from a region — e.g. the workspace
    /// title bar — that defines no cursor rect of its own).
    override func cursorUpdate(with event: NSEvent) {
        (isTracking ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // One area over the whole grip: `.mouseEnteredAndExited` reveals/hides the
        // three dots, and `.cursorUpdate` makes AppKit call `cursorUpdate` over the
        // grip so it can set the hand cursor.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        // Also set the cursor here (not only in `cursorUpdate`): entering from the
        // window toolbar above the top pane fires `mouseEntered` but not
        // `cursorUpdate`. Mirrors `GhosttySurfaceView`.
        (isTracking ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        // Reset to arrow so the hand does not leak onto sibling chrome (toolbar,
        // divider); the terminal restores its I-beam via its own `cursorUpdate` when
        // the pointer moves onto it. Mirrors `GhosttySurfaceView.mouseExited`.
        NSCursor.arrow.set()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The grip appears only on hover, mirroring Ghostty's `SurfaceGrabHandle`
        // (its ellipsis is absent unless hovering). `hovering`'s `didSet` marks the
        // view for redraw, so toggling hover repaints.
        guard hovering else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.75).setFill()

        let diameter: CGFloat = 3.5
        let gap: CGFloat = 5
        let totalWidth = diameter * 3 + gap * 2
        let startX = bounds.midX - totalWidth / 2
        let y = bounds.midY - diameter / 2
        for i in 0..<3 {
            let x = startX + CGFloat(i) * (diameter + gap)
            NSBezierPath(ovalIn: CGRect(x: x, y: y, width: diameter, height: diameter)).fill()
        }
    }

    // MARK: - Drag source

    override func mouseDown(with event: NSEvent) {
        // Intentionally no `super`: that would let the window begin a background
        // drag instead of arming our own pane drag. The whole view is the grip, so
        // any press on it arms a potential drag.
        pressed = true
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let local = convert(event.locationInWindow, from: nil)
        let travelled = hypot(local.x - mouseDownLocation.x, local.y - mouseDownLocation.y)
        guard travelled > Self.dragSlop else { return }
        pressed = false  // Begin once; further drags in this session are ignored.
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
    }

    private func beginDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        // `.string` is `public.utf8-plain-text`, a system-registered type SwiftUI's
        // `.onDrop` reliably matches — unlike a code-declared UTType with no Info.plist.
        item.setString(surfaceID.uuidString, forType: .string)

        let image = Self.makeDragImage(label: label)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let origin = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            CGRect(x: origin.x - image.size.width / 2, y: origin.y - image.size.height / 2,
                   width: image.size.width, height: image.size.height),
            contents: image)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
        onDragStateChange(true)
    }

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    /// Flip `cursorUpdate` to the closed hand for the duration of the drag.
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isTracking = true
    }

    /// Re-assert the closed hand as the drag moves, matching Ghostty. After the drop,
    /// the terminal under the pointer heals to its I-beam via its own `cursorUpdate`
    /// on the next move — nothing to restore here.
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        isTracking = false
        onDragStateChange(false)
    }

    /// A lightweight drag preview (rounded card with a terminal icon and label).
    /// A live Metal snapshot is out of scope; this is enough to track the cursor.
    private static func makeDragImage(label: String) -> NSImage {
        let size = CGSize(width: 160, height: 40)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let card = NSBezierPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        let iconRect = CGRect(x: 12, y: (size.height - 18) / 2, width: 18, height: 18)
        NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.draw(in: iconRect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = label as NSString
        let textHeight = text.size(withAttributes: attributes).height
        text.draw(
            in: CGRect(x: 38, y: (size.height - textHeight) / 2, width: size.width - 48, height: textHeight),
            withAttributes: attributes)
        return image
    }
}

/// SwiftUI wrapper placing a `PaneDragHandleView` above the pane content.
struct PaneDragHandle: NSViewRepresentable {
    let surfaceID: UUID
    let label: String
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> PaneDragHandleView {
        PaneDragHandleView(surfaceID: surfaceID, label: label, onDragStateChange: onDragStateChange)
    }

    func updateNSView(_ nsView: PaneDragHandleView, context: Context) {}
}

/// SwiftUI drop TARGET for one pane. Reads the dragged `Surface.id`, tracks the
/// nearest-edge drop zone for the highlight overlay, and on drop asks the model
/// to relocate the pane beside this one. A self-drop is ignored.
struct PaneDropDelegate: DropDelegate {
    let targetID: UUID
    /// Delivers the drop's Sendable inputs; the callback computes the zone and
    /// applies the move on the main actor (`LayoutTree.DropZone` is not Sendable,
    /// so it must never cross the concurrency boundary).
    let move: @Sendable (_ sourceID: UUID, _ location: CGPoint, _ size: CGSize) -> Void
    @Binding var size: CGSize
    /// Report/clear the hover zone in the model. Non-Sendable closures are fine:
    /// `DropDelegate` methods run on the main actor, so no boundary is crossed.
    let setHover: (LayoutTree.DropZone) -> Void
    let clearHover: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropEntered(info: DropInfo) {
        setHover(LayoutTree.dropZone(at: info.location, in: size))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        setHover(LayoutTree.dropZone(at: info.location, in: size))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearHover()
    }

    func performDrop(info: DropInfo) -> Bool {
        clearHover()
        guard let provider = info.itemProviders(for: [.utf8PlainText]).first else {
            return false
        }

        // Capture only Sendable values; the zone is computed inside `move` on the
        // main actor so the non-Sendable `DropZone` never crosses a boundary.
        let location = info.location
        let size = size
        let targetID = targetID
        let move = move
        provider.loadDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier) { data, _ in
            // A non-UUID payload is some other text drag we don't own: treat it as a
            // parse failure and no-op, filtering it out.
            guard let data, let string = String(data: data, encoding: .utf8),
                  let sourceID = UUID(uuidString: string)
            else {
                return
            }
            guard sourceID != targetID else { return }
            DispatchQueue.main.async {
                move(sourceID, location, size)
            }
        }
        return true
    }
}

/// Attaches the pane drop target only when dragging is enabled (a multi-pane
/// workspace). Conditionally applying `.onDrop` inline would change the view's
/// type between branches; a modifier keeps the identity stable.
struct PaneDropTarget: ViewModifier {
    let enabled: Bool
    let delegate: PaneDropDelegate

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.utf8PlainText], delegate: delegate)
        } else {
            content
        }
    }
}

/// AppKit-backed accent highlight over the half a drop would land in, with a
/// subtle border. It is an `NSView` — not a SwiftUI overlay — because the pane
/// content is a Metal-backed terminal view that composites ABOVE sibling SwiftUI
/// content regardless of `ZStack` order; only a real `NSView` sibling draws in
/// front of it. Purely decorative: `hitTest` returns nil so every mouse event
/// passes through to the terminal below.
final class PaneDropHighlightView: NSView {
    var zone: LayoutTree.DropZone? {
        didSet { if zone != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left origin, matching SwiftUI, so the zone rects match `PaneDropDelegate`'s.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let zone else { return }
        let cornerRadius: CGFloat = 4
        let rect = frame(for: zone)

        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

        let borderWidth: CGFloat = 1.5
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = borderWidth
        NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
        border.stroke()
    }

    private func frame(for zone: LayoutTree.DropZone) -> CGRect {
        switch zone {
        case .top:
            return CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2)
        case .bottom:
            return CGRect(x: 0, y: bounds.height / 2, width: bounds.width, height: bounds.height / 2)
        case .left:
            return CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
        case .right:
            return CGRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height)
        }
    }
}

/// SwiftUI wrapper placing a `PaneDropHighlightView` above the pane content, so
/// the highlight composites over the Metal terminal surface.
struct PaneDropHighlight: NSViewRepresentable {
    let zone: LayoutTree.DropZone?

    func makeNSView(context: Context) -> PaneDropHighlightView {
        PaneDropHighlightView(frame: .zero)
    }

    func updateNSView(_ nsView: PaneDropHighlightView, context: Context) {
        nsView.zone = zone
    }
}
