import SwiftUI

struct CasperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            // No minimum window size is declared on purpose: the floor is whatever
            // AppKit enforces for a titled window, measured at 298 x 141 pt. Nothing in
            // the view tree adds one either — GhosttySurfaceView is an
            // NSViewRepresentable with no intrinsic size and collapses to 0 pt wide,
            // NavigationSplitView's `.navigationSplitViewColumnWidth(min: 220, ...)`
            // constrains the sidebar column and not the window, the toolbar is a real
            // NSToolbar whose items overflow into the chevron menu rather than imposing
            // a width, and Text truncates. So at the floor the terminal surface really
            // does render at 0 px / 1 column x 3 rows. That is accepted: the window must
            // shrink freely, with no minimum imposed on the terminal surface either.
            // (The former `.frame(minWidth: 900, minHeight: 560)` dated back to the
            // initial scene commit and was never calibrated.)
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
