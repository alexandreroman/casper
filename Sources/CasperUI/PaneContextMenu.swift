import AppKit
import CasperCore

/// An `NSMenuItem` that runs a stored closure when fired, targeting itself so no
/// separate target object has to be kept alive. Mirrors SwiftUI `Button` actions
/// for the AppKit context menu built by `AppModel.paneContextMenu(for:)`.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

extension AppModel {
    /// The AppKit twin of `SurfaceHostView.paneMenu`, shown when a terminal pane is
    /// right-clicked and the terminal is not capturing the mouse. Items mirror the
    /// SwiftUI menu exactly so the pane menu stays defined in one shape: four
    /// splits, copy/paste, and close.
    func paneContextMenu(for surfaceID: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Split Up", systemImage: "rectangle.tophalf.filled") {
            [weak self] in self?.applySplit(from: surfaceID, direction: .up)
        })
        menu.addItem(ClosureMenuItem(title: "Split Down", systemImage: "rectangle.bottomhalf.filled") {
            [weak self] in self?.applySplit(from: surfaceID, direction: .down)
        })
        menu.addItem(ClosureMenuItem(title: "Split Left", systemImage: "rectangle.lefthalf.filled") {
            [weak self] in self?.applySplit(from: surfaceID, direction: .left)
        })
        menu.addItem(ClosureMenuItem(title: "Split Right", systemImage: "rectangle.righthalf.filled") {
            [weak self] in self?.applySplit(from: surfaceID, direction: .right)
        })
        menu.addItem(.separator())
        // Copy/Paste dispatch through the responder chain to the focused
        // `GhosttySurfaceView`, exactly like `SurfaceHostView.paneMenu`.
        menu.addItem(ClosureMenuItem(title: "Copy", systemImage: "doc.on.doc") {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        })
        menu.addItem(ClosureMenuItem(title: "Paste", systemImage: "clipboard") {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Close Pane", systemImage: "xmark") {
            [weak self] in self?.applyCloseSurface(surfaceID)
        })
        return menu
    }
}
