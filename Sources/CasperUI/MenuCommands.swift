import AppKit
import CasperCore
import SwiftUI

/// Casper's entire menu bar, expressed as SwiftUI `Commands` so SwiftUI owns the
/// main menu end to end. This is deliberate: Casper previously built the bar
/// imperatively in AppKit (`NSApp.mainMenu = …`), but SwiftUI's `WindowGroup`
/// re-synchronises `NSApp.mainMenu` on scene-lifecycle events and wiped those
/// imperative menus — dropping File/Edit and re-injecting Format/Help. Owning the
/// menu through `.commands` removes that race: SwiftUI re-applies these same
/// definitions on every resync, so there is nothing left to clobber.
///
/// Menus are positioned by *replacing the standard command-group placements*
/// rather than adding `CommandMenu`s, so each menu lands in its native slot and a
/// group left empty makes its menu disappear entirely:
/// - File   ← `.newItem`   (other File groups emptied)
/// - Edit   ← `.pasteboard` (other Edit groups emptied)
/// - View   ← `.sidebar`   (`.toolbar` emptied)
/// - Format ← `.textFormatting` emptied (menu removed)
/// - Help   ← `.help` emptied (menu removed)
/// - App / Window ← SwiftUI defaults
struct CasperCommands: Commands {
    let model: AppModel

    var body: some Commands {
        // File menu.
        Group {
            CommandGroup(replacing: .newItem) {
                Button { model.presentAddFolderPanel() } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                Button {
                    guard let space = model.targetSpaceForNewWorkspace() else { return }
                    model.presentAddLinkedWorkspacePanel(spaceID: space.id)
                } label: {
                    Label("Create Workspace…", systemImage: "plus")
                }
                .disabled(!model.menuCanCreateWorkspace)
                Divider()
                Button {
                    guard let id = model.selectedWorkspaceID else { return }
                    model.openInFinder(id: id)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                .disabled(!model.menuHasSelectedWorkspace)
                Divider()
                Button {
                    guard let id = model.selectedWorkspaceID else { return }
                    model.presentCloseWorkspaceConfirmation(id: id)
                } label: {
                    Label("Merge and Close Workspace…", systemImage: "arrow.triangle.merge")
                }
                .disabled(!model.menuCanCloseSelectedWorkspace)
                Button {
                    guard let id = model.selectedWorkspaceID else { return }
                    model.presentDeleteWorkspaceConfirmation(id: id)
                } label: {
                    Label("Delete Workspace…", systemImage: "trash")
                }
                .disabled(!model.menuCanDeleteSelectedWorkspace)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .importExport) {}
            CommandGroup(replacing: .printItem) {}
        }

        // Edit menu. Copy/Paste/Select All carry no target: NSApp.sendAction walks
        // the responder chain to the focused GhosttySurfaceView, exactly like the
        // AppKit pane context menu in PaneContextMenu.swift.
        Group {
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {
                Button {
                    guard let id = model.selectedWorkspaceID else { return }
                    model.copyWorkspacePath(id: id)
                } label: {
                    Label("Copy Workspace Path", systemImage: "doc.on.doc")
                }
                .disabled(!model.menuHasSelectedWorkspace)
                Button {
                    guard let id = model.selectedWorkspaceID else { return }
                    model.copyBranchName(id: id)
                } label: {
                    Label("Copy Branch Name", systemImage: "doc.on.doc")
                }
                .disabled(!model.menuHasSelectedWorkspace)
                Divider()
                Button { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                Button { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } label: {
                    Label("Paste", systemImage: "clipboard")
                }
                .keyboardShortcut("v", modifiers: .command)
                Button { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } label: {
                    Label("Select All", systemImage: "square.dashed")
                }
                .keyboardShortcut("a", modifiers: .command)
            }
            CommandGroup(replacing: .textEditing) {}
            // Format menu removed: emptying `.textFormatting` drops its items; the
            // resulting empty stub is stripped in AppDelegate.stripEmptyTopLevelMenus().
            CommandGroup(replacing: .textFormatting) {}
        }

        // View menu: the four pane splits. These items are ALWAYS enabled — the
        // action itself no-ops when no terminal is focused. The enable-state was
        // intentionally dropped: gating it on the focused surface made the SwiftUI
        // `.commands` body observe `focusedSurfaceID`, so SwiftUI re-asserted the
        // whole native menu on every focus change (momentarily recreating the empty
        // Format/Help stubs) — a visible menu-bar flicker. Zero flash beats greying.
        CommandGroup(replacing: .sidebar) {
            Button { model.applyNewSplit(.up) } label: {
                Label("Split Up", systemImage: "rectangle.tophalf.filled")
            }
            Button { model.applyNewSplit(.down) } label: {
                Label("Split Down", systemImage: "rectangle.bottomhalf.filled")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button { model.applyNewSplit(.left) } label: {
                Label("Split Left", systemImage: "rectangle.lefthalf.filled")
            }
            Button { model.applyNewSplit(.right) } label: {
                Label("Split Right", systemImage: "rectangle.righthalf.filled")
            }
            .keyboardShortcut("d", modifiers: .command)
            Divider()
        }
        CommandGroup(replacing: .toolbar) {}

        // Help menu removed: emptying `.help` drops its items; the resulting empty
        // stub is stripped in AppDelegate.stripEmptyTopLevelMenus().
        CommandGroup(replacing: .help) {}
    }
}

extension AppModel {
    /// Enable-state for the File menu's "Create Workspace…": a space to create into.
    var canCreateWorkspace: Bool { targetSpaceForNewWorkspace() != nil }

    /// Enable-state for "Delete Workspace…": only a linked worktree can be deleted.
    var canDeleteSelectedWorkspace: Bool { menuSelectedWorkspace?.kind == .linked }

    /// Enable-state for "Merge and Close Workspace…": a linked workspace that still
    /// records the base branch to merge back into.
    var canCloseSelectedWorkspace: Bool {
        guard let workspace = menuSelectedWorkspace, workspace.kind == .linked else { return false }
        return !(workspace.baseBranch?.isEmpty ?? true)
    }

    /// Enable-state for the Edit menu's "Copy Workspace Path" / "Copy Branch Name".
    var hasSelectedWorkspace: Bool { selectedWorkspaceID != nil }

    private var menuSelectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspace(id: id)
    }
}
