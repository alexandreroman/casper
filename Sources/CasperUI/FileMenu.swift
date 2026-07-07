import AppKit
import CasperCore

extension AppModel {
    /// The "File" menu inserted into the app's main menu bar by `AppDelegate`:
    /// folder onboarding. Every item stays enabled at all times, so this menu
    /// needs no delegate-driven validation.
    func fileMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "File")
        submenu.addItem(ClosureMenuItem(title: "Add folder…", systemImage: "plus") {
            [weak self] in self?.presentAddFolderPanel()
        })

        let item = NSMenuItem()
        item.submenu = submenu
        return item
    }
}
