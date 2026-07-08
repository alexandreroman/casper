import SwiftUI

struct CasperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        // Casper builds its entire menu bar imperatively in AppDelegate (App/Edit/Window
        // from GhosttyMenu, plus its own File and View menus). Without this modifier the
        // WindowGroup still owns SwiftUI's implicit default command groups, which it
        // reasserts over NSApp.mainMenu on scene-lifecycle events (e.g. window
        // miniaturize/deminiaturize) — dropping our File menu, overwriting View, and
        // injecting a stray Help menu. Neutralizing every default group Casper already
        // provides in AppKit leaves SwiftUI nothing to re-inject.
        // Grouped by menu (Group conforms to Commands) to stay within the commands
        // builder's 10-child limit and keep each menu's groups together.
        .commands {
            // File menu (Casper builds its own in FileMenu.swift).
            Group {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .importExport) {}
                CommandGroup(replacing: .printItem) {}
            }

            // Edit menu (Casper builds its own via GhosttyMenu.swift).
            Group {
                CommandGroup(replacing: .undoRedo) {}
                CommandGroup(replacing: .pasteboard) {}
                CommandGroup(replacing: .textEditing) {}
                CommandGroup(replacing: .textFormatting) {}
            }

            // View menu (Casper builds its own in ViewMenu.swift).
            Group {
                CommandGroup(replacing: .toolbar) {}
                CommandGroup(replacing: .sidebar) {}
            }

            // Window menu (Casper builds its own via GhosttyMenu.swift).
            Group {
                CommandGroup(replacing: .windowSize) {}
                CommandGroup(replacing: .windowList) {}
                CommandGroup(replacing: .windowArrangement) {}
            }

            // Help menu: Casper has none, so removing SwiftUI's default drops it entirely.
            CommandGroup(replacing: .help) {}
        }
    }
}
