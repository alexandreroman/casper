import CasperCore
import SwiftUI

/// One item of a workspace's action menu. The menu is offered in two forms — the
/// sidebar row's SwiftUI `.contextMenu` (`SidebarView`) and the Space/Edit menu-bar
/// groups (`CasperCommands`) — and both render this one description, so their
/// titles, symbols and actions cannot drift apart.
///
/// Enable-state is supplied by the caller rather than derived here, because the two
/// call sites read it from different places: the menu bar uses the edge-triggered
/// `menuCan*` flags, while a sidebar row derives it from the workspace it already
/// renders.
@MainActor
struct WorkspaceMenuItem {
    /// The actions a workspace offers, each carrying the title and symbol both
    /// menus render.
    enum Command {
        case openInFinder
        case copyWorkspacePath
        case copyBranchName
        case mergeAndClose
        case delete

        var title: String {
            switch self {
            case .openInFinder: return "Open in Finder"
            case .copyWorkspacePath: return "Copy Workspace Path"
            case .copyBranchName: return "Copy Branch Name"
            case .mergeAndClose: return "Merge and Close Workspace…"
            case .delete: return "Delete Workspace…"
            }
        }

        var systemImage: String {
            switch self {
            case .openInFinder: return "folder"
            case .copyWorkspacePath, .copyBranchName: return "doc.on.doc"
            case .mergeAndClose: return "arrow.triangle.merge"
            case .delete: return "trash"
            }
        }

        /// Rendered as a destructive button by the sidebar's context menu; the menu
        /// bar renders it plain, as the native main menu carries no destructive
        /// styling (the same split as `PaneMenuItem.commandKey`, which only the
        /// SwiftUI twin advertises).
        var isDestructive: Bool { self == .delete }

        @MainActor
        func perform(model: AppModel, workspaceID: UUID) {
            switch self {
            case .openInFinder: model.openInFinder(id: workspaceID)
            case .copyWorkspacePath: model.copyWorkspacePath(id: workspaceID)
            case .copyBranchName: model.copyBranchName(id: workspaceID)
            case .mergeAndClose: model.presentCloseWorkspaceConfirmation(id: workspaceID)
            case .delete: model.presentDeleteWorkspaceConfirmation(id: workspaceID)
            }
        }
    }

    let title: String
    let systemImage: String
    let isDestructive: Bool
    let isEnabled: Bool
    let action: () -> Void

    private init(command: Command, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = command.title
        self.systemImage = command.systemImage
        self.isDestructive = command.isDestructive
        self.isEnabled = isEnabled
        self.action = action
    }

    /// An item acting on one specific workspace.
    static func item(
        _ command: Command, model: AppModel, workspaceID: UUID, isEnabled: Bool
    ) -> WorkspaceMenuItem {
        // `weak`: a menu outlives the click that built it.
        WorkspaceMenuItem(command: command, isEnabled: isEnabled) { [weak model] in
            guard let model else { return }
            command.perform(model: model, workspaceID: workspaceID)
        }
    }

    /// An item acting on whatever workspace is selected when it fires. Resolving the
    /// id inside the action, instead of at build time, is what keeps the menu-bar
    /// `Commands` body from observing `selectedWorkspaceID`: SwiftUI re-asserts the
    /// whole native menu whenever that body is invalidated, which flickers the bar.
    static func selectedWorkspaceItem(
        _ command: Command, model: AppModel, isEnabled: Bool
    ) -> WorkspaceMenuItem {
        WorkspaceMenuItem(command: command, isEnabled: isEnabled) { [weak model] in
            guard let model, let id = model.selectedWorkspaceID else { return }
            command.perform(model: model, workspaceID: id)
        }
    }

    /// The workspace menu for `workspaceID`, as the groups the sidebar separates
    /// with a divider: reveal, copy, merge-and-close, delete.
    static func groups(
        model: AppModel, workspaceID: UUID, isEnabled: (Command) -> Bool
    ) -> [[WorkspaceMenuItem]] {
        func make(_ command: Command) -> WorkspaceMenuItem {
            item(command, model: model, workspaceID: workspaceID, isEnabled: isEnabled(command))
        }
        return [
            [make(.openInFinder)],
            [make(.copyWorkspacePath), make(.copyBranchName)],
            [make(.mergeAndClose)],
            [make(.delete)],
        ]
    }
}
