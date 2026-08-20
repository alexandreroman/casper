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

/// One item of the pane context menu. The menu is shown in two forms — the
/// SwiftUI `.contextMenu` in `SurfaceHostView.paneMenu` and the AppKit twin
/// `AppModel.paneContextMenu(for:)` — and both render this one description, so
/// their titles, symbols, ordering and actions cannot drift apart.
@MainActor
struct PaneMenuItem {
    let title: String
    let systemImage: String
    /// Command-key equivalent, advertised by the SwiftUI menu only; the AppKit
    /// twin's items carry no key equivalent.
    let commandKey: Character?
    /// Rendered as a destructive button by SwiftUI; AppKit has no equivalent.
    let isDestructive: Bool
    let action: () -> Void

    init(title: String, systemImage: String, commandKey: Character? = nil,
         isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.commandKey = commandKey
        self.isDestructive = isDestructive
        self.action = action
    }

    /// The pane menu for `surfaceID`, as the groups both renderers separate with a
    /// divider: four splits, copy/paste, close.
    ///
    /// Splits always create a terminal. Copy/Paste fire their Edit-menu selector
    /// down the responder chain, reaching the focused `GhosttySurfaceView` (mirrors
    /// the Edit-menu Copy/Paste in `CasperCommands` (MenuCommands.swift), which also
    /// dispatch through the responder chain), so on a browser/diff pane they act on
    /// the focused terminal rather than the pane itself.
    static func groups(model: AppModel, surfaceID: UUID) -> [[PaneMenuItem]] {
        func split(_ title: String, _ systemImage: String, _ direction: GhosttySplitDirectionLike) -> PaneMenuItem {
            // `weak`: the AppKit menu outlives the click that built it.
            PaneMenuItem(title: title, systemImage: systemImage) { [weak model] in
                model?.applySplit(from: surfaceID, direction: direction)
            }
        }
        return [
            [
                split("Split Up", "rectangle.tophalf.filled", .up),
                split("Split Down", "rectangle.bottomhalf.filled", .down),
                split("Split Left", "rectangle.lefthalf.filled", .left),
                split("Split Right", "rectangle.righthalf.filled", .right),
            ],
            [
                PaneMenuItem(title: "Copy", systemImage: "doc.on.doc", commandKey: "c") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                },
                PaneMenuItem(title: "Paste", systemImage: "clipboard", commandKey: "v") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                },
            ],
            [
                PaneMenuItem(title: "Close Pane", systemImage: "xmark", isDestructive: true) { [weak model] in
                    model?.applyCloseSurface(surfaceID)
                },
            ],
        ]
    }
}

extension AppModel {
    /// The AppKit twin of `SurfaceHostView.paneMenu`, shown when a terminal pane is
    /// right-clicked and the terminal is not capturing the mouse. Both are built
    /// from `PaneMenuItem.groups(model:surfaceID:)`, so the two menus stay identical.
    func paneContextMenu(for surfaceID: UUID) -> NSMenu {
        let menu = NSMenu()
        for (index, group) in PaneMenuItem.groups(model: self, surfaceID: surfaceID).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in group {
                menu.addItem(ClosureMenuItem(
                    title: item.title, systemImage: item.systemImage, handler: item.action))
            }
        }
        return menu
    }
}
