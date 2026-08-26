import AppKit
import CasperCore
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
                        // Give the detail a per-workspace identity so its `@State
                        // inspectorWidth` re-seeds from this workspace's persisted
                        // `inspector.width` on `.onAppear`; without it, one workspace's
                        // dragged width would carry across a switch.
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
        // Fast path only: the window is usually there by the next runloop turn, which
        // attaches the observers before the first `updateNSView`. `updateNSView` is
        // what guarantees attachment when this hop loses the race.
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
        guard let window = nsView.window else { return }
        // Attachment is event-driven rather than one-shot: if `makeNSView`'s async hop
        // ran before the view had a window, nothing would ever install the occlusion
        // observer and `isWindowVisible` would stay `true` for the whole session.
        // `attach(to:)` is idempotent, so calling it on every update is free.
        context.coordinator.attach(to: window)
        // Past the first attach the `didUpdateNotification` observer keeps these
        // applied, so only write when the value actually differs — `updateNSView` runs
        // on every `RootView` re-evaluation (spaces/selection changes).
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

        /// Whether `attach(to:)` has already run. Both `makeNSView`'s async seed and
        /// every `updateNSView` call it — whichever first sees a window wins — so it
        /// has to be idempotent. Re-running it would also re-write
        /// `model.isWindowVisible` on every view update, and `@Observable` notifies on
        /// each write, so an unguarded call would invalidate the view that triggered it.
        private var attached = false

        init(model: AppModel) { self.model = model }

        /// Push the window's current visibility to the model and reconcile
        /// watchers. Single source of the occlusion predicate for both the
        /// initial seed and the occlusion-change observer.
        private func refreshVisibility(_ window: NSWindow) {
            model.isWindowVisible = window.occlusionState.contains(.visible)
            model.applyWatcherVisibility()
        }

        func attach(to window: NSWindow) {
            guard !attached else { return }
            attached = true
            window.titleVisibility = .hidden
            // Removes the "Icon and Text / Icon Only" toolbar display-mode context
            // menu that AppKit shows on a right-/control-click of the toolbar.
            window.toolbar?.allowsDisplayModeCustomization = false
            // Seed the visibility signal from the window's current state.
            refreshVisibility(window)
            WindowFloor.apply(model.terminalHostMetrics, to: window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    // The toolbar can be recreated on updates, so re-apply this
                    // unconditionally rather than behind the title-visibility guard.
                    window.toolbar?.allowsDisplayModeCustomization = false
                    // Safety net for the window-driven cases (a sidebar drag lands
                    // here). The view pushes the floor itself whenever the room it
                    // measures changes, which is the authoritative trigger.
                    WindowFloor.apply(self?.model.terminalHostMetrics, to: window)
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


/// What the window's floor is computed from: the widths flanking the terminal
/// region, and the detail column's height against which the window's own chrome is
/// measured.
///
/// Every term is measured rather than assumed. The sidebar's CURRENT width matters,
/// not its column minimum: the sidebar does not give way as the window narrows — the
/// detail column absorbs the whole shrink — so a floor built on the 220 pt minimum
/// would still let the terminal be squeezed whenever the sidebar is wider.
struct TerminalHostMetrics: Equatable {
    /// The sidebar's width, and 0 while it is collapsed.
    ///
    /// Never read below the column's own minimum while the sidebar is open: at a
    /// window already narrower than the floor the sidebar is squeezed too, and a
    /// floor derived from that squeezed width would ratify the very state it exists
    /// to prevent. Clamping to the minimum makes the floor climb out instead — each
    /// pass widens the window, the sidebar recovers, and the next pass sees its real
    /// width. The climb is monotone and stops at the true floor.
    let sidebarWidth: CGFloat
    /// The inspector panel plus its separator, and 0 while the panel is collapsed.
    let inspectorSlice: CGFloat
    /// The height the detail column spends on something other than the pane tree.
    let detailChromeHeight: CGFloat
}

/// The window's lower bound, derived from the room the terminal region needs.
///
/// A SwiftUI content minimum does NOT reach the window on its own: a
/// `.frame(minWidth:minHeight:)` inside `NavigationSplitView` is answered by clipping
/// the content, not by refusing to shrink, so `NSWindow.contentMinSize` is the only
/// thing that actually stops a drag. Measured, not assumed — a 380 pt window leaves
/// the detail column 80 pt wide however large a minimum the pane tree declares.
enum WindowFloor {
    /// Applies the floor implied by `metrics`.
    ///
    /// Built from the pieces flanking the terminal rather than from the room it
    /// currently has, because the floor has to be computable from a state that is
    /// already too small. A relative formula ("content minus terminal, plus the
    /// minimum") reads elegantly and deadlocks: below the floor the terminal measures
    /// zero or negative, which says nothing about how much room the rest of the row
    /// needs, so the floor collapses and the window can never climb back out.
    ///
    /// Width is the sidebar and the inspector at their current widths plus the
    /// terminal's minimum. Height goes through the window because only the window
    /// knows how much of its content the toolbar takes: everything above and below
    /// the pane tree is `content − detail + the detail's own chrome`.
    ///
    /// It converges rather than chasing itself: not one term depends on the window's
    /// size, so raising the floor resizes the window and the next pass computes the
    /// same floor. The write is skipped when nothing moved, which matters because
    /// `didUpdateNotification` fires constantly.
    ///
    /// ## What this does not do, and why
    ///
    /// SwiftUI competes for the same properties. A `WindowGroup` recomputes the
    /// window's minimums from its content on every view update and writes them back —
    /// measured at **228 x 142**, a figure that folds in the terminal's own 200 pt
    /// minimum but credits the sidebar 28 pt where it is really 300. So this floor
    /// holds by writing LAST, not by owning the value, and it is re-applied on every
    /// window update for that reason.
    ///
    /// Steering that computation from the content side does not work either: a
    /// `.frame(minWidth: 220)` on the sidebar column leaves SwiftUI's figure at
    /// 228 x 145. A content minimum does not reach `NSWindow` from anywhere in the
    /// tree.
    ///
    /// The authoritative mechanism is `NSWindowDelegate.windowWillResize(_:to:)`,
    /// which clamps a live drag and cannot be overwritten. It is deliberately NOT
    /// taken: it means taking the window's delegate away from SwiftUI. The accepted
    /// consequence is that the floor holds from ordinary states — where it is the
    /// user's drag or an opening inspector that moves things — and not from a window
    /// already collapsed below it, which normal use does not reach.
    @MainActor
    static func apply(_ metrics: TerminalHostMetrics?, to window: NSWindow) {
        let floor: CGSize
        if let metrics {
            let minimum = WorkspaceDetailView.terminalMinimumSize
            // Everything the window spends above the content: the titlebar and the
            // unified toolbar. Taken from the window itself — `contentLayoutRect` is
            // the part of the content the toolbar does NOT cover — rather than from
            // the difference between the content and the detail column, because the
            // detail column collapses along with the window and would take the floor
            // down with it.
            let content = window.contentRect(forFrameRect: window.frame).size
            let toolbarHeight = max(0, content.height - window.contentLayoutRect.height)
            floor = CGSize(
                width: metrics.sidebarWidth + metrics.inspectorSlice + minimum,
                height: toolbarHeight + metrics.detailChromeHeight + minimum)
        } else {
            // No workspace on screen: AppKit's own floor, so the empty state is not
            // held open by whatever the last workspace needed.
            floor = .zero
        }
        #if DEBUG
        CasperLog.app.debug(
            """
            TIERPROBE WINDOWFLOOR sidebar=\(metrics?.sidebarWidth ?? -1, privacy: .public) \
            inspector=\(metrics?.inspectorSlice ?? -1, privacy: .public) \
            content=\(window.contentRect(forFrameRect: window.frame).height, privacy: .public) \
            layout=\(window.contentLayoutRect.height, privacy: .public) \
            floor=\(floor.width, privacy: .public)x\(floor.height, privacy: .public)
            """)
        #endif
        // BOTH minimums, because SwiftUI owns one of them: a `WindowGroup` recomputes
        // `contentMinSize` from its content on every view update and writes it back —
        // measured at 228 x 142, which credits the sidebar 28 pt when it is really
        // 300 — so a value written only there is clobbered within the frame. The
        // frame-based `minSize` is not SwiftUI's to manage, and it is what holds.
        let frameFloor = window.frameRect(forContentRect: CGRect(origin: .zero, size: floor)).size
        if abs(window.minSize.width - frameFloor.width) > 0.5
            || abs(window.minSize.height - frameFloor.height) > 0.5 {
            window.minSize = frameFloor
        }
        if abs(window.contentMinSize.width - floor.width) > 0.5
            || abs(window.contentMinSize.height - floor.height) > 0.5 {
            window.contentMinSize = floor
        }
        grow(window, toAtLeast: floor)
    }

    /// Grows a window that is already smaller than its floor.
    ///
    /// `contentMinSize` constrains a DRAG; it does not resize a window that is
    /// under it already. Without this, opening the inspector on a small window
    /// raises the floor above the window and simply leaves it there, with the
    /// terminal squeezed below its minimum — the floor would only bite the next time
    /// the user reached for the window's edge.
    ///
    /// The top-left corner is held so the window grows down and to the right, the
    /// direction a window is expected to move when its content demands more room.
    /// This cannot oscillate: the floor is computed from the sidebar and inspector
    /// widths, neither of which is a function of the window's size, so the pass that
    /// follows this resize computes the same floor and finds nothing left to do.
    @MainActor
    private static func grow(_ window: NSWindow, toAtLeast floor: CGSize) {
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width < floor.width - 0.5 || content.height < floor.height - 0.5 else {
            return
        }
        let grown = CGSize(
            width: max(content.width, floor.width), height: max(content.height, floor.height))
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: grown))
        frame.origin.x = window.frame.minX
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
    }

    /// Applies the floor to whichever window is showing the workspace UI.
    @MainActor
    static func apply(_ metrics: TerminalHostMetrics?) {
        for window in NSApp.windows where window.isVisible && window.toolbar != nil {
            apply(metrics, to: window)
        }
    }
}
