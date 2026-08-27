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
/// group left empty makes its menu disappear entirely. The list below names the
/// *placement* on the right and the *visible title* on the left; the two differ for
/// one menu: Casper's items go in the standard File slot but the menu reads "Space",
/// retitled in AppKit by `AppDelegate.renameFileMenu(in:)` because `.commands` can
/// position a group into a standard menu but not rename one.
/// - Space  ← `.newItem`   (other File groups emptied)
/// - Edit   ← `.pasteboard` (other Edit groups emptied)
/// - View   ← `.sidebar`   (`.toolbar` emptied)
/// - Format ← `.textFormatting` emptied (menu removed)
/// - Help   ← `.help` emptied (menu removed)
/// - App    ← `.appInfo` (the one *additive* group: "Check for Updates…"),
///            everything else SwiftUI defaults
/// - Window ← SwiftUI defaults
struct CasperCommands: Commands {
    /// Title of the first item of the standard File slot, and the marker
    /// `AppDelegate.renameFileMenu(in:)` matches that menu on — it is Casper's own
    /// string, so unlike the standard File items macOS does not localize it. Keep
    /// this item first in the `.newItem` group below.
    static let newSpaceTitle = "New Space…"

    let model: AppModel

    var body: some Commands {
        // App menu: offer the update check only when this bundle is actually wired
        // for Sparkle (see SoftwareUpdater) — a dead menu item is worse than none.
        // `isEnabled` is constant for the process lifetime, so unlike the enable-state
        // flags below it makes this body observe nothing volatile and cannot provoke
        // the menu-bar resync flicker.
        CommandGroup(after: .appInfo) {
            if SoftwareUpdater.shared.isEnabled {
                Button { SoftwareUpdater.shared.checkForUpdates() } label: {
                    Label("Check for Updates…", systemImage: "arrow.down.circle")
                }
            }
        }

        // Space menu (the standard File slot, retitled in AppDelegate).
        Group {
            CommandGroup(replacing: .newItem) {
                Button { model.presentCreateSpacePanel() } label: {
                    Label(Self.newSpaceTitle, systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)
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
                workspaceButton(.openInFinder, isEnabled: model.menuHasSelectedWorkspace)
                Divider()
                workspaceButton(.mergeAndClose, isEnabled: model.menuCanCloseSelectedWorkspace)
                workspaceButton(.delete, isEnabled: model.menuCanDeleteSelectedWorkspace)
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
                workspaceButton(.copyWorkspacePath, isEnabled: model.menuHasSelectedWorkspace)
                workspaceButton(.copyBranchName, isEnabled: model.menuHasSelectedWorkspace)
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

    /// A menu-bar item acting on the selected workspace, built from the same
    /// `WorkspaceMenuItem` description the sidebar row's context menu renders.
    /// `isEnabled` comes from the edge-triggered `menuCan*` flags, and the item's
    /// destructive styling is deliberately left unapplied — the native main menu
    /// has none.
    private func workspaceButton(_ command: WorkspaceMenuItem.Command, isEnabled: Bool) -> some View {
        let item = WorkspaceMenuItem.selectedWorkspaceItem(command, model: model, isEnabled: isEnabled)
        return Button(action: item.action) {
            Label(item.title, systemImage: item.systemImage)
        }
        .disabled(!item.isEnabled)
    }
}

extension AppModel {
    /// Enable-state for the Space menu's "Create Workspace…": a space to create into.
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
