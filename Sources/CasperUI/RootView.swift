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
                        // `ideal` is the width the sidebar opens at: enough room for a typical
                        // branch label beside the row's leading glyphs and trailing 20pt slot.
                        .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 400)
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
        // Attached to the whole `Group` so the sheet is presented the same way in
        // the empty-state and the split-view branch. The binding only ever accepts
        // being nil-ed out: `closeProgress` is model-owned, and SwiftUI's dismissal
        // is the sole write the view is allowed to make.
        .sheet(
            item: Binding(
                get: { model.closeProgress },
                set: { if $0 == nil { model.closeProgress = nil } }
            )
        ) { progress in
            WorkspaceCloseProgressView(progress: progress)
                // No Cancel button, and no way to dismiss: neither the merge nor the
                // worktree removal can be stopped midway without leaving the repository
                // half-done, so the sheet stays up until the operation clears it.
                .interactiveDismissDisabled()
        }
        // Asks SwiftUI not to put a title in the title bar. SwiftUI owns
        // `titleVisibility` — it writes it from the window controller and again on
        // every view-graph update — so removing the title item here is what keeps the
        // title from ever being drawn; see `WindowConfigurator` for why hiding it at
        // the AppKit level can only be a fallback. Attached to the whole `Group` so it
        // covers the empty-state and the split-view branch alike.
        .toolbar(removing: .title)
        .background(WindowConfigurator(model: model))
        .onChange(of: model.spaces.isEmpty) { _, empty in
            // When the first space is added, expand the sidebar by default. Only
            // reacts to the empty↔non-empty transition, so manual sidebar toggling
            // during normal multi-space use isn't overridden.
            if !empty { columnVisibility = .all }
        }
    }
}

/// Applies the per-window AppKit settings `RootView` needs: the toolbar's
/// display-mode customization is turned off, occlusion changes are forwarded to
/// the model, and the window title text is hidden as a fallback.
///
/// `.toolbar(removing: .title)` on `RootView` — not this — is what keeps the
/// title off screen. Hiding it here cannot be the primary mechanism because it
/// always loses the launch race: SwiftUI sets the title while the window loads,
/// long before `makeNSView`'s async hop reaches `attach(to:)`, so the title is
/// drawn for that whole gap. A `Coordinator` still re-hides it on every window
/// update, as a cheap safety net.
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
        // The `didUpdateNotification` observer already keeps these applied, so only
        // write when the value actually differs — `updateNSView` runs on every
        // `RootView` re-evaluation (spaces/selection changes) and these are redundant.
        guard let window = nsView.window else { return }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if let toolbar = window.toolbar, toolbar.allowsDisplayModeCustomization {
            toolbar.allowsDisplayModeCustomization = false
        }
    }

    @MainActor
    final class Coordinator {
        private let model: AppModel
        // `nonisolated(unsafe)` is safe here: both are only ever mutated from
        // `attach(to:)` on the main actor, and by the time `deinit` runs no other
        // reference to the object exists, so there's no concurrent access to race
        // with (and `NotificationCenter.removeObserver` is itself thread-safe). This
        // lets `deinit` read them without a main-actor hop — avoiding the `isolated
        // deinit` back-deployment shim that SIGABRTs on the CI runner (see the
        // isolated-deinit-ci-sigabrt project memory note).
        nonisolated(unsafe) private var observer: NSObjectProtocol?
        nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?

        init(model: AppModel) { self.model = model }

        /// Push the window's current visibility to the model and reconcile
        /// watchers. Single source of the occlusion predicate for both the
        /// initial seed and the occlusion-change observer.
        private func refreshVisibility(_ window: NSWindow) {
            model.isWindowVisible = window.occlusionState.contains(.visible)
            model.applyWatcherVisibility()
        }

        func attach(to window: NSWindow) {
            window.titleVisibility = .hidden
            // Removes the "Icon and Text / Icon Only" toolbar display-mode context
            // menu that AppKit shows on a right-/control-click of the toolbar.
            window.toolbar?.allowsDisplayModeCustomization = false
            // Seed the visibility signal from the window's current state.
            refreshVisibility(window)
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    // The toolbar can be recreated on updates, so re-apply this
                    // unconditionally rather than behind the title-visibility guard.
                    window.toolbar?.allowsDisplayModeCustomization = false
                    // Fallback only, and a lagging one: a re-shown title stays on
                    // screen until the *next* window update — in practice until the
                    // user moves the mouse. `.toolbar(removing: .title)` is what
                    // actually keeps it away.
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
                    self?.refreshVisibility(window)
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
        }
    }
}
