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
/// The bar holds one menu per object level, in the order App, Space, Workspace, Edit,
/// View, Window: Space for the project, Workspace for the selected worktree, and View
/// for how the window shows it. Menus are positioned through the *standard
/// command-group placements* — mostly by replacing them — so each menu lands in its
/// native slot and a group left empty makes its menu disappear entirely. The one
/// exception is Workspace, a `CommandMenu`: no standard menu fits it, and SwiftUI
/// lands an additive menu between View and Window, which `.commands` cannot change —
/// so `AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in:)` moves it after Space in
/// AppKit, on every update pass. The list below names the *placement* on the right
/// and the *visible title* on the left; the two differ for one menu: Casper's items
/// go in the standard File slot but the menu reads "Space", retitled in AppKit by
/// `AppDelegate.renameFileMenu(in:)` because `.commands` can position a group into a
/// standard menu but not rename one.
/// - Space     ← `.newItem`   (other File groups emptied)
/// - Workspace ← `CommandMenu(workspaceMenuTitle)`, moved after Space in AppKit
/// - Edit      ← `.pasteboard` (other Edit groups emptied)
/// - View      ← `SidebarCommands` in `.sidebar`, the inspector toggles and the
///               splits after it (`.toolbar` emptied)
/// - Format    ← `.textFormatting` emptied (menu removed)
/// - Help      ← `.help` emptied (menu removed)
/// - App       ← `.appInfo` (an *additive* group: "Check for Updates…"),
///               everything else SwiftUI defaults
/// - Window    ← SwiftUI defaults
///
/// Every enable-state and checkmark below reads an edge-triggered `menu…` flag on
/// `AppModel`, and every action resolves the selected workspace when it fires: the
/// body must never observe the selection itself (see `WorkspaceMenuItem`).
struct CasperCommands: Commands {
    /// Title of the first item of the standard File slot, and the marker
    /// `AppDelegate.renameFileMenu(in:)` matches that menu on — it is Casper's own
    /// string, so unlike the standard File items macOS does not localize it. Read
    /// off `allCases`, which the `.newItem` group below lists first, so reordering
    /// the cases cannot desync the marker; keep that `ForEach` first in the group.
    static let newSpaceTitle = SpaceEntryCommand.allCases[0].title

    /// Title of the Workspace menu, and the marker
    /// `AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in:)` finds it by — Casper's own
    /// string, so macOS does not localize it.
    static let workspaceMenuTitle = "Workspace"

    /// Title and symbol of "Remove Space…", shared with the sidebar's Space header
    /// context menu so the two cannot drift apart.
    static let removeSpaceTitle = "Remove Space…"
    static let removeSpaceSystemImage = "folder.badge.minus"

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

        // Space menu (the standard File slot, retitled in AppDelegate): the two ways
        // into a Space, then the way out of the selected workspace's Space.
        Group {
            CommandGroup(replacing: .newItem) {
                ForEach(SpaceEntryCommand.allCases, id: \.self) { command in
                    Button { command.perform(model: model) } label: {
                        Label(command.title, systemImage: command.systemImage)
                    }
                    .keyboardShortcut(command.keyboardShortcut)
                }
                Divider()
                Button {
                    guard let space = model.selectedSpace else { return }
                    model.presentRemoveSpaceConfirmation(id: space.id)
                } label: {
                    Label(Self.removeSpaceTitle, systemImage: Self.removeSpaceSystemImage)
                }
                .disabled(!model.menuCanRemoveSelectedSpace)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .importExport) {}
            CommandGroup(replacing: .printItem) {}
        }

        // Edit menu: the standard Copy/Paste/Select All, nothing else. They carry no
        // target: NSApp.sendAction walks the responder chain to the focused
        // GhosttySurfaceView, exactly like the AppKit pane context menu in
        // PaneContextMenu.swift.
        Group {
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {
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
            // resulting empty stub is stripped in AppDelegate.stripEmptyTopLevelMenus(in:).
            CommandGroup(replacing: .textFormatting) {}
        }

        // View menu: SwiftUI's standard Show/Hide Sidebar (⌃⌘S), which drives the
        // `NavigationSplitView` column, then the inspector's Diff / Browser toggles and
        // the four pane splits. They go *after* `.sidebar` rather than replacing it,
        // since replacing the group would drop the toggle `SidebarCommands` places
        // there.
        //
        // The splits are ALWAYS enabled — the action itself no-ops when no terminal is
        // focused. The enable-state was intentionally dropped: gating it on the focused
        // surface made the SwiftUI `.commands` body observe `focusedSurfaceID`, so
        // SwiftUI re-asserted the whole native menu on every focus change (momentarily
        // recreating the empty Format/Help stubs) — a visible menu-bar flicker. Zero
        // flash beats greying.
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Divider()
            inspectorToggle(.diff, title: "Diff", systemImage: "plusminus")
            inspectorToggle(.browser, title: "Browser", systemImage: "globe")
            Divider()
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

        // Workspace menu (moved after Space in AppDelegate): everything that acts on the
        // selected workspace. Open in Editor and Run Script are plain items rather than
        // the title bar's submenus, because a submenu listing the selected workspace's
        // editors or scripts would make this body observe the selection; each runs what
        // the matching title-bar chip's primary action runs.
        CommandMenu(Self.workspaceMenuTitle) {
            Button { model.presentNewWorkspacePanel() } label: {
                Label("New Workspace…", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.menuCanCreateWorkspace)
            Divider()
            workspaceButton(.showInFinder, isEnabled: model.menuHasSelectedWorkspace)
            Button {
                guard let id = model.selectedWorkspaceID else { return }
                model.openInEditor(nil, for: id)
            } label: {
                Label("Open in Editor", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .disabled(!model.menuCanOpenSelectedWorkspaceInEditor)
            Button {
                guard let id = model.selectedWorkspaceID else { return }
                model.runResolvedScript(for: id)
            } label: {
                Label("Run Script", systemImage: "play")
            }
            .disabled(!model.menuCanRunSelectedWorkspaceScript)
            Divider()
            workspaceButton(.copyWorkspacePath, isEnabled: model.menuHasSelectedWorkspace)
            workspaceButton(.copyBranchName, isEnabled: model.menuHasSelectedWorkspace)
            Divider()
            workspaceButton(.mergeAndClose, isEnabled: model.menuCanCloseSelectedWorkspace)
            workspaceButton(.delete, isEnabled: model.menuCanDeleteSelectedWorkspace)
        }

        // Help menu removed: emptying `.help` drops its items; the resulting empty
        // stub is stripped in AppDelegate.stripEmptyTopLevelMenus(in:).
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

    /// A View menu toggle for one inspector tab, checkmarked while that tab is the
    /// one showing — the title bar's Diff / Browser control, item for item. Both
    /// route through `toggleInspectorTab`, so choosing the checked tab collapses the
    /// panel and choosing the other switches to it.
    ///
    /// The checkmark is read here, during the body, rather than inside the binding's
    /// getter, so the observation is registered on the edge-triggered flag.
    private func inspectorToggle(_ tab: InspectorTab, title: String, systemImage: String) -> some View {
        let isShowing = model.menuInspectorTab == tab
        let binding = Binding(
            get: { isShowing },
            set: { _ in
                guard let id = model.selectedWorkspaceID else { return }
                model.toggleInspectorTab(tab, for: id)
            })
        return Toggle(isOn: binding) {
            Label(title, systemImage: systemImage)
        }
        .disabled(!model.menuHasSelectedWorkspace)
    }
}

extension AppModel {
    /// Enable-state for the Workspace menu's "New Workspace…": a space to create into.
    var canCreateWorkspace: Bool { targetSpaceForNewWorkspace() != nil }

    /// Enable-state for "Delete Workspace…": only a linked worktree can be deleted.
    var canDeleteSelectedWorkspace: Bool { menuSelectedWorkspace?.kind == .linked }

    /// Enable-state for "Merge and Close Workspace…" — `Workspace.canMerge`.
    var canCloseSelectedWorkspace: Bool { menuSelectedWorkspace?.canMerge ?? false }

    /// Enable-state for every item acting on the selected workspace without a further
    /// condition — "Show in Finder", the two copies and the inspector toggles.
    var hasSelectedWorkspace: Bool { selectedWorkspaceID != nil }

    /// Enable-state for "Open in Editor": `resolvedEditor` falls back to the first
    /// detected editor, so any detected editor means the item launches something.
    var canOpenSelectedWorkspaceInEditor: Bool { hasSelectedWorkspace && !availableEditors.isEmpty }

    /// Enable-state for "Run Script": a named command to resolve, and no `setup` hook
    /// still running — the same gate as the Run chip's primary action.
    var canRunSelectedWorkspaceScript: Bool {
        guard let id = selectedWorkspaceID else { return false }
        return !namedCommands(for: id).isEmpty && !isSetupRunning(in: id)
    }

    /// Enable-state for "Remove Space…": a selected Space with none of its workspaces
    /// being closed or deleted. The progress sheet of such an operation blocks the
    /// sidebar but not the menu bar, and a Space removed mid-merge would leave the
    /// merged primary worktree un-resynced and the worktree and branch on disk.
    var canRemoveSelectedSpace: Bool {
        guard let space = selectedSpace else { return false }
        return !space.workspaces.contains { closingWorkspaces.contains($0.id) }
    }

    /// The checkmark of the View menu's Diff / Browser toggles.
    var selectedInspectorTab: InspectorTab? { menuSelectedWorkspace?.inspector.visibleTab }

    /// The Space the selected workspace belongs to — what "Remove Space…" removes.
    var selectedSpace: Space? {
        guard let workspace = menuSelectedWorkspace else { return nil }
        return space(for: workspace)
    }

    private var menuSelectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspace(id: id)
    }
}
