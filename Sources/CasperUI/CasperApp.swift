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
        .commands { CasperCommands(model: model) }
    }
}
