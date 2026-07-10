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
    private let createItem: NSMenuItem
    private let closeItem: NSMenuItem
    private let deleteItem: NSMenuItem

    init(model: AppModel, createItem: NSMenuItem, closeItem: NSMenuItem, deleteItem: NSMenuItem) {
        self.model = model
        self.createItem = createItem
        self.closeItem = closeItem
        self.deleteItem = deleteItem
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        var selected: Workspace?
        if let id = model?.selectedWorkspaceID {
            selected = model?.workspace(id: id)
        }
        createItem.isEnabled = model?.targetSpaceForNewWorkspace() != nil
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
        let addFolderItem = ClosureMenuItem(title: "Add Folder…", systemImage: "plus") {
            [weak self] in self?.presentAddFolderPanel()
        }
        addFolderItem.keyEquivalent = "o"
        addFolderItem.keyEquivalentModifierMask = .command
        let createWorkspaceItem = ClosureMenuItem(title: "Create Workspace…", systemImage: "plus") {
            [weak self] in
            guard let self, let space = self.targetSpaceForNewWorkspace() else { return }
            self.presentAddLinkedWorkspacePanel(spaceID: space.id)
        }
        submenu.addItem(addFolderItem)
        submenu.addItem(createWorkspaceItem)
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

        let delegate = FileMenuDelegate(
            model: self, createItem: createWorkspaceItem, closeItem: closeItem, deleteItem: deleteItem)
        fileMenuDelegate = delegate
        submenu.delegate = delegate

        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }

    /// The "Copy Workspace Path" item inserted at the top of the Edit menu
    /// (above Copy/Paste/Select All). Copies the selected workspace's path;
    /// disabled when no workspace is selected. Injected by
    /// `AppDelegate.installCustomMainMenu`, since the Edit menu itself is built
    /// in the CasperGhostty module with no `AppModel` access.
    func copyWorkspacePathMenuItem() -> NSMenuItem {
        ClosureMenuItem(title: "Copy Workspace Path", systemImage: "doc.on.doc",
                        isEnabled: { [weak self] in self?.selectedWorkspaceID != nil }) {
            [weak self] in
            guard let self, let id = self.selectedWorkspaceID else { return }
            self.copyWorkspacePath(id: id)
        }
    }

    /// The "Copy Branch Name" item appended to the Edit menu (beside "Copy
    /// Workspace Path"). Copies the selected workspace's branch name; disabled
    /// when no workspace is selected. Injected by
    /// `AppDelegate.installCustomMainMenu`, since the Edit menu itself is built
    /// in the CasperGhostty module with no `AppModel` access.
    func copyBranchNameMenuItem() -> NSMenuItem {
        ClosureMenuItem(title: "Copy Branch Name", systemImage: "doc.on.doc",
                        isEnabled: { [weak self] in self?.selectedWorkspaceID != nil }) {
            [weak self] in
            guard let self, let id = self.selectedWorkspaceID else { return }
            self.copyBranchName(id: id)
        }
    }
}
