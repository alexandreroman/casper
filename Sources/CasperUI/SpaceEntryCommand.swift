import SwiftUI

/// The two ways into a Space: create one from nothing, or adopt a folder that
/// already exists. The Space menu, the sidebar footer and the empty state all render
/// this one description, so their titles, symbols and actions cannot drift apart —
/// and since each site lists `allCases`, they cannot disagree on the order either
/// (app-ui.md § Design → "Ways into a Space").
enum SpaceEntryCommand: CaseIterable {
    case create
    case adopt

    var title: String {
        switch self {
        case .create: return "New Space…"
        case .adopt: return "Add Folder…"
        }
    }

    var systemImage: String {
        switch self {
        case .create: return "folder.badge.plus"
        case .adopt: return "plus"
        }
    }

    /// The Space menu's shortcut. New Space… takes ⇧⌘N because plain ⌘N belongs to
    /// New Workspace…, the action reached for most — and the one libghostty's own ⌘N
    /// binding is routed to while a terminal is focused (`LayoutActionHandler`).
    var keyboardShortcut: KeyboardShortcut {
        switch self {
        case .create: return KeyboardShortcut("n", modifiers: [.command, .shift])
        case .adopt: return KeyboardShortcut("o", modifiers: .command)
        }
    }

    @MainActor
    func perform(model: AppModel) {
        switch self {
        case .create: model.presentCreateSpacePanel()
        case .adopt: model.presentAddFolderPanel()
        }
    }
}
