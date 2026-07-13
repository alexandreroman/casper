import SwiftUI

struct CasperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
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
        .commands { CasperCommands(model: model) }
    }
}
