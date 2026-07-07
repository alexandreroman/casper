import AppKit
import CasperCore

/// Bridges AppKit's `@objc` `NSMenuDelegate` protocol to `AppModel`, which is a
/// plain `@Observable` class (not an `NSObject` subclass) and so cannot conform
/// to an `@objc` protocol directly. Revalidates the View menu's four split
/// items against `AppModel.focusedSurfaceID` each time the menu is about to
/// display — `NSMenu` does not otherwise revalidate `ClosureMenuItem`s, which
/// carry no `NSMenuItemValidation`-conforming target of their own.
@MainActor
final class ViewMenuDelegate: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private let splitItems: [NSMenuItem]

    init(model: AppModel, splitItems: [NSMenuItem]) {
        self.model = model
        self.splitItems = splitItems
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let enabled = model?.focusedSurfaceID != nil
        for item in splitItems { item.isEnabled = enabled }
    }
}

extension AppModel {
    /// The "View" menu inserted into the app's main menu bar by `AppDelegate`:
    /// the four pane splits, mirroring `paneContextMenu(for:)` but scoped to
    /// whichever pane currently has focus rather than a specific right-clicked
    /// one. The split items are disabled while no pane is focused (see
    /// `ViewMenuDelegate`).
    func viewMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "View")
        // This menu manages its own items via `ViewMenuDelegate`, so autoenabling must
        // stay off — otherwise AppKit's automatic validation pass re-enables the split
        // items right after `menuNeedsUpdate` disables them (unlike the Edit menu in
        // `GhosttyMenu.swift`, which relies on autoenabling + `validateMenuItem`).
        submenu.autoenablesItems = false

        let splits: [(title: String, systemImage: String, direction: GhosttySplitDirectionLike,
                       key: String, keyModifiers: NSEvent.ModifierFlags)] = [
            ("Split Up", "rectangle.tophalf.filled", .up, "", []),
            ("Split Down", "rectangle.bottomhalf.filled", .down, "d", [.command, .shift]),
            ("Split Left", "rectangle.lefthalf.filled", .left, "", []),
            ("Split Right", "rectangle.righthalf.filled", .right, "d", [.command]),
        ]
        let splitItems = splits.map { entry -> NSMenuItem in
            let item = ClosureMenuItem(title: entry.title, systemImage: entry.systemImage) {
                [weak self] in self?.applyNewSplit(entry.direction)
            }
            item.keyEquivalent = entry.key
            item.keyEquivalentModifierMask = entry.keyModifiers
            return item
        }
        splitItems.forEach(submenu.addItem)

        let delegate = ViewMenuDelegate(model: self, splitItems: splitItems)
        viewMenuDelegate = delegate
        submenu.delegate = delegate

        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }
}
