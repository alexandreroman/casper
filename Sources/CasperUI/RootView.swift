import AppKit
import SwiftUI

struct RootView: View {
    let model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if model.spaces.isEmpty {
                // No space configured: show only the empty state — no
                // NavigationSplitView, so there is no sidebar and no sidebar
                // toggle in the toolbar at all.
                EmptyStateView(onAddFolder: { model.presentAddFolderPanel() })
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                } detail: {
                    if let id = model.selectedWorkspaceID, let workspace = model.workspace(id: id) {
                        // Give the detail a per-workspace identity so SwiftUI recreates the
                        // `.inspector` on a workspace switch. Otherwise SwiftUI retains a single
                        // scene-level inspector width and carries it across workspaces; a fresh
                        // identity forces the column width to re-seed from this workspace's
                        // persisted `inspector.width`.
                        WorkspaceDetailView(model: model, workspace: workspace)
                            .id(id)
                    } else {
                        // Unreachable in practice: a non-empty `spaces` always has a selected,
                        // resolvable workspace (AppModel selection invariant — see `addSpace`,
                        // `fallbackSelection`, and session restore; locked by `AppModelTests`).
                        // Kept only to satisfy the `detail` closure's exhaustiveness, and so the
                        // misleading "No workspace yet." never renders where workspaces exist.
                        Color.clear
                    }
                }
            }
        }
        .background(WindowConfigurator(model: model))
        .onChange(of: model.spaces.isEmpty) { _, empty in
            // When the first space is added, expand the sidebar by default. Only
            // reacts to the empty↔non-empty transition, so manual sidebar toggling
            // during normal multi-space use isn't overridden.
            if !empty { columnVisibility = .all }
        }
    }
}

/// Hides the hosting window's title text (the centered title in the title bar)
/// while keeping the title bar and toolbar. Applied per-window so it does not
/// depend on app-activation timing.
///
/// The `NavigationSplitView` re-shows the title whenever the sidebar collapses,
/// so a `Coordinator` observes the window and re-hides it on every update.
private struct WindowConfigurator: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `Context` is only guaranteed valid during this call, so capture the
        // retained coordinator before hopping onto the escaping async block.
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainActor.assumeIsolated { coordinator.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = .hidden
        nsView.window?.toolbar?.allowsDisplayModeCustomization = false
    }

    @MainActor
    final class Coordinator {
        private let model: AppModel
        private var observer: NSObjectProtocol?
        private var occlusionObserver: NSObjectProtocol?

        init(model: AppModel) { self.model = model }

        func attach(to window: NSWindow) {
            window.titleVisibility = .hidden
            // Removes the "Icon and Text / Icon Only" toolbar display-mode context
            // menu that AppKit shows on a right-/control-click of the toolbar.
            window.toolbar?.allowsDisplayModeCustomization = false
            // Seed the visibility signal from the window's current state.
            model.isWindowVisible = window.occlusionState.contains(.visible)
            model.applyWatcherVisibility()
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    // The toolbar can be recreated on updates, so re-apply this
                    // unconditionally rather than behind the title-visibility guard.
                    window.toolbar?.allowsDisplayModeCustomization = false
                    guard window.titleVisibility != .hidden else { return }
                    window.titleVisibility = .hidden
                }
            }
            // Minimize, cover, and off-Space all drop `.visible` from
            // occlusionState, so this one observer covers every "hidden" case.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.model.isWindowVisible = window.occlusionState.contains(.visible)
                    self?.model.applyWatcherVisibility()
                }
            }
        }

        isolated deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
        }
    }
}
