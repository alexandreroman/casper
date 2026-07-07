import AppKit
import CasperCore

/// Bridges AppKit's `@objc` `NSMenuDelegate` protocol to `AppModel`, which is a
/// plain `@Observable` class (not an `NSObject` subclass) and so cannot conform
/// to an `@objc` protocol directly. Revalidates the File menu's merge/delete
/// items against the selected workspace each time the menu is about to
/// display — `NSMenu` does not otherwise revalidate `ClosureMenuItem`s, which
/// carry no `NSMenuItemValidation`-conforming target of their own.
@MainActor
final class FileMenuDelegate: NSObject, NSMenuDelegate {
    private weak var model: AppModel?
    private let closeItem: NSMenuItem
    private let deleteItem: NSMenuItem

    init(model: AppModel, closeItem: NSMenuItem, deleteItem: NSMenuItem) {
        self.model = model
        self.closeItem = closeItem
        self.deleteItem = deleteItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        var selected: Workspace?
        if let id = model?.selectedWorkspaceID {
            selected = model?.workspace(id: id)
        }
        deleteItem.isEnabled = selected?.kind == .linked
        closeItem.isEnabled = selected?.kind == .linked && !(selected?.baseBranch?.isEmpty ?? true)
    }
}

extension AppModel {
    /// The "File" menu inserted into the app's main menu bar by `AppDelegate`:
    /// folder onboarding, plus merge/delete for the selected workspace. Both
    /// dynamic items are disabled while not applicable (see `FileMenuDelegate`).
    func fileMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "File")
        // This menu manages its own items via `FileMenuDelegate`, so autoenabling must
        // stay off — otherwise AppKit's automatic validation pass re-enables the merge/
        // delete items right after `menuNeedsUpdate` disables them.
        submenu.autoenablesItems = false
        submenu.addItem(ClosureMenuItem(title: "Add Folder…", systemImage: "plus") {
            [weak self] in self?.presentAddFolderPanel()
        })
        submenu.addItem(.separator())

        let closeItem = ClosureMenuItem(
            title: "Merge and Close Workspace…", systemImage: "arrow.triangle.merge"
        ) {
            [weak self] in
            guard let self, let id = self.selectedWorkspaceID else { return }
            self.presentCloseWorkspaceConfirmation(id: id)
        }
        let deleteItem = ClosureMenuItem(
            title: "Delete Workspace…", systemImage: "trash", tint: .systemRed
        ) {
            [weak self] in
            guard let self, let id = self.selectedWorkspaceID else { return }
            self.presentDeleteWorkspaceConfirmation(id: id)
        }
        submenu.addItem(closeItem)
        submenu.addItem(deleteItem)

        let delegate = FileMenuDelegate(model: self, closeItem: closeItem, deleteItem: deleteItem)
        fileMenuDelegate = delegate
        submenu.delegate = delegate

        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }
}
