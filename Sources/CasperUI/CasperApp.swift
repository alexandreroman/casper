import SwiftUI

struct CasperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            // No minimum window size is declared HERE on purpose: the window's floor
            // is not a number picked for the window, it is whatever the content
            // requires. `WorkspaceDetailView.terminalMinimumSize` is the one
            // calibrated floor — 200 x 200 pt for the terminal region — and the
            // window can be dragged down to whatever that implies once the sidebar
            // and the inspector are added beside it.
            //
            // Nothing else in the tree adds a minimum: `NavigationSplitView`'s
            // `.navigationSplitViewColumnWidth(min: 220, ...)` constrains the sidebar
            // column and not the window, the toolbar is a real `NSToolbar` whose
            // items overflow into the chevron menu rather than imposing a width, and
            // Text truncates. AppKit's own floor for a titled window measures
            // 298 x 141 pt, which is what the window shrank to when the terminal
            // region had no floor of its own — a surface rendering 1 column x 3 rows.
            //
            // A window minimum re-declared here would be a second, uncalibrated
            // number competing with the content's: the reason the original
            // `.frame(minWidth: 900, minHeight: 560)` was removed was that it was
            // never calibrated against anything.
            RootView(model: model)
        }
        // Casper owns its entire menu bar through SwiftUI `.commands` (see
        // CasperCommands). Doing this in SwiftUI rather than mutating NSApp.mainMenu
        // in AppKit is what keeps the bar stable: SwiftUI re-applies these menus on
        // every scene-lifecycle resync instead of clobbering an AppKit-built menu.
        //
        // Note: `.commandsRemoved()` is deliberately NOT used here. It removes *all*
        // default commands (Apple: "Removes all commands defined by the modified
        // scene"), including the native App menu (About/Settings/Services/Hide/Quit)
        // and Window menu (Minimize/Zoom/Bring All to Front) — and there is no public
        // API to re-add a single default group afterwards. Format/Help are instead
        // removed by emptying `.textFormatting`/`.help` in CasperCommands and
        // stripping the leftover empty stubs in AppDelegate.stripEmptyTopLevelMenus().
        // Services alone is dropped from the App menu — there is no CommandGroup for
        // it either, so AppDelegate.resyncMainMenu() removes it in AppKit.
        .commands { CasperCommands(model: model) }
    }
}
