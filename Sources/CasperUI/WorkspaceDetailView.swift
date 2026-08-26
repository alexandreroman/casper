import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    let model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed on
    /// appear and on every diff revision (see `refreshDiffSummary`).
    @State private var diff: (insertions: Int, deletions: Int)?

    /// The in-flight summary refresh, if any. Cancelled and replaced on every new
    /// revision so rapid changes can't leave two tasks racing to settle `diff` on a
    /// stale value, and cancelled on disappear so none outlives this view.
    @State private var diffSummaryTask: Task<Void, Never>?

    /// Live inspector width, seeded per-workspace on appear (the detail view has
    /// a per-workspace `.id`, so this resets on every workspace switch) and
    /// persisted on drag-end. Held locally so the divider drag never mutates
    /// observed model state mid-layout.
    @State private var inspectorWidth: Double?

    /// The detail area's frame in window coordinates, or `nil` until the first
    /// layout pass has measured it. `nil` means "not measured yet", which the chip
    /// row must read as roomy: a row that started out folded and unfolded a frame
    /// later would flicker on every workspace switch.
    @State private var detailFrame: CGRect?

    /// Floor for the TERMINAL region — the pane tree, not the inspector panel and
    /// not the sidebar. Calibrated so a surface stays usable: `GhosttySurfaceView`
    /// has no intrinsic size of its own and collapses to nothing given the chance,
    /// and a terminal a few points wide renders a one-column sliver that can display
    /// no output worth reading.
    ///
    /// This is where the window's own floor comes from: no minimum is declared on
    /// the window (see `CasperApp`), so whatever this implies once the sidebar and
    /// the inspector are added is what the window can be dragged down to.
    static let terminalMinimumSize: CGFloat = 200

    /// Keep at least this much room for the detail area when clamping the
    /// inspector's maximum width.
    private static let minDetailWidth: Double = 320

    /// Gap between two adjacent title-bar capsules.
    ///
    /// Measured off a 2× screenshot of the shipped row: the Merge capsule's
    /// trailing edge and the Run capsule's leading edge sit ~15 px apart, i.e.
    /// 7.5 pt. 8 pt therefore reproduces the spacing AppKit was inserting between
    /// the separate toolbar items that the collapsible chips now share.
    static let chipGap: CGFloat = 8

    /// Room the window's own chrome takes out of the toolbar row this view shares,
    /// counted only when the detail area starts at the window's leading edge.
    ///
    /// When the sidebar is open, the traffic lights and the sidebar toggle sit over
    /// the sidebar column and cost the detail's region nothing. When it is
    /// collapsed, the detail starts at the window's leading edge and that same
    /// chrome eats into the row. `minX` is how this view knows which case it is in:
    /// `RootView`'s `columnVisibility` is private `@State` and is not reachable
    /// from here.
    ///
    /// Measured on a real `NSWindow` + `NSToolbar` carrying the standard
    /// toggle-sidebar item: the traffic lights push the first toolbar content to
    /// x = 92, and that item's viewer measures 48 pt. 92 + 48 = 140.
    static let windowChromeReserve: CGFloat = 140

    /// Deliberate undershoot on the row's width.
    ///
    /// The two failures are wildly asymmetric. A row a few points narrower than the
    /// bar leaves a sliver of empty space at the trailing edge that nobody will ever
    /// notice. A row a few points wider overflows the ONE item that now holds every
    /// title-bar control, emptying the whole title bar into AppKit's chevron — so
    /// this is sized to lose that race on purpose, not calibrated to fit exactly.
    static let safetyMargin: CGFloat = 24

    /// Narrowest row worth mounting. The `⋯` chip alone measures 34 pt, so below
    /// this there is nothing left to draw — and at such a width the detail area is
    /// a sliver anyway (a 320 pt window leaves it 22 pt beside the sidebar).
    ///
    /// The row is then dropped from the toolbar entirely rather than shown at a few
    /// points wide, because AppKit cannot fit ANY item into a bar that narrow and
    /// would answer with the overflow chevron. No item, nothing to overflow.
    static let minimumRowWidth: CGFloat = 40

    /// Width the row takes while the detail area has not been measured yet.
    ///
    /// Small on purpose: unmeasured must mean NARROW. At this width the chips start
    /// folded and grow once the real width arrives, which costs at most one frame of
    /// a `⋯` chip — where starting wide would cost an overflowed row, and an
    /// overflowed row does not always come back on its own.
    static let unmeasuredRowWidth: CGFloat = 240

    /// Stable coordinate space for the inspector divider drag, anchored to the
    /// full-width detail container so the pointer's absolute location is read
    /// against a fixed origin (the divider itself moves as the panel resizes).
    private static let inspectorDragSpace = "inspectorDrag"

    var body: some View {
        GeometryReader { proxy in
            let range = inspectorRange(container: proxy.size.width)
            let width = (inspectorWidth ?? workspace.inspector.width)
                .clamped(to: range)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    LayoutNodeView(
                        model: model, workspaceID: workspace.id, node: workspace.layout,
                        canDragPanes: Self.hasMultiplePanes(in: workspace.layout))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: Self.terminalMinimumSize, minHeight: Self.terminalMinimumSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The inspector region (divider + panel) is ALWAYS mounted and
                // pinned at its full width; collapsing animates the OUTER clip
                // width to zero instead of unmounting the panel with a `.move`
                // transition. Revealing by clipping keeps the panel at fixed
                // coordinates (content pinned to the trailing edge, which is the
                // window's fixed right edge) so nothing translates, mirroring
                // `SplitContainerView`'s always-mounted, frame-animated
                // approach. The divider lives inside the same clipped container
                // so it reveals with the panel rather than popping in as a
                // separate mount.
                HStack(spacing: 0) {
                    inspectorDivider(total: proxy.size.width, range: range)
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: width)
                }
                .frame(width: workspace.inspector.collapsed ? 0 : SeparatorMetrics.visibleWidth + width,
                       alignment: .trailing)
                .clipped()
            }
            .coordinateSpace(.named(Self.inspectorDragSpace))
            .animation(.easeInOut(duration: 0.18), value: workspace.inspector.collapsed)
        }
        // Measured on the `GeometryReader` ITSELF, not on the content inside it. A
        // reader takes exactly the space its column offers; that content does not.
        // At a narrow window the inspector panel's minimum width pushes the content
        // WIDER than the column, which simply clips it — measured at a 450 pt window
        // with the panel open, the split divider stays at x = 300 and the column is
        // 150 pt wide, while the content reports 241 pt starting at x = 209. Handing
        // `rowWidth` that 241 is what overflows the toolbar item, and an overflowed
        // item does not come back: neither invalidation, nor a toolbar reset, nor a
        // window nudge recovers it, because at that width it genuinely does not fit.
        //
        // Captured from an ACTION rather than read off the reader's own proxy: that
        // proxy is only reachable inside the body, and writing `@State` from inside a
        // body is what SwiftUI warns about. The whole frame, not just the size — the
        // origin is what tells `rowWidth` whether the window's own chrome shares this
        // row.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { detailFrame = $0 }
        // The window's floor is rebuilt from this, so it has to be republished when
        // the inspector moves as well as when the detail area does — the panes' share
        // is what is left after the panel takes its slice.
        .onChange(of: terminalHostMetrics) { _, metrics in publish(metrics) }
        .onAppear { publish(terminalHostMetrics) }
        .onDisappear { publish(nil) }
        .toolbar {
            // EVERY title-bar control lives in this ONE item: title, info chip, diff
            // badge, Merge, Run Script, Editor and the inspector selector.
            //
            // Not a stylistic grouping — it is the only structure that cannot end up
            // in AppKit's overflow chevron, where these custom chips render without
            // their capsule chrome and the segmented control clips to a lone glyph.
            // A `ToolbarItem`'s hosted view is sized to its content's IDEAL width and
            // AppKit will not shrink it below that: faced with a bar too narrow, it
            // overflows the item whole rather than proposing it less. Measured on the
            // running app at a 600 pt window, where the leading group alone reported
            // 293 pt and went into the chevron with the title still one truncatable
            // line. So the only reliable rule is to hand AppKit a single item that is
            // never wider than the bar, and to do the degrading ourselves inside it.
            if rowWidth >= Self.minimumRowWidth {
                ToolbarItem(placement: .navigation) {
                    WorkspaceTitleBarRow(
                        model: model, workspace: workspace, diff: diff, width: rowWidth)
                }
                .flatToolbarItem()
            }
        }
        .alert("Couldn't Open Editor", isPresented: Binding(
            get: { model.editorLaunchError != nil },
            set: { if !$0 { model.editorLaunchError = nil } }
        )) {
            // Empty: dismissing the alert flips `isPresented` to false, and that
            // binding's setter is what clears the error.
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.editorLaunchError ?? "")
        }
        .alert("Couldn't Run Script", isPresented: Binding(
            get: { model.scriptRunError != nil },
            set: { if !$0 { model.scriptRunError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.scriptRunError ?? "")
        }
        // Two triggers, because the row can outgrow the bar for two unrelated
        // reasons: the window narrowed, or the CONTENT changed while the window
        // stood still (opening the inspector, a diff summary arriving, a script
        // appearing). `rowWidth` catches only the first.
        .onChange(of: rowWidth) { _, _ in Self.healToolbarOverflow() }
        .onChange(of: workspace.inspector) { _, _ in Self.healToolbarOverflow() }
        .onAppear {
            // `RootView` gives this view a per-workspace `.id`, so one instance only
            // ever renders one workspace — the first summary needs no keying.
            refreshDiffSummary()
            #if DEBUG
            probeToolbarState()
            #endif
        }
        .onChange(of: model.diffRevision) { _, _ in
            refreshDiffSummary()
        }
        .onDisappear {
            // Switching workspaces tears this instance down and discards its `@State`;
            // without this the git diff behind the last refresh would keep running,
            // holding `model`, to produce a summary nothing can display any more.
            diffSummaryTask?.cancel()
        }
    }

    #if DEBUG
    /// TEMPORARY diagnostic: resizes the window across `CASPER_TIERPROBE_WIDTHS`
    /// and logs, at each width, what AppKit did with the toolbar items.
    private func probeToolbarState() {
        guard let list = ProcessInfo.processInfo.environment["CASPER_TIERPROBE_WIDTHS"] else { return }
        let widths = list.split(separator: ",").compactMap { Double($0) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            for width in widths {
                guard let window = NSApp.windows.first(where: { $0.toolbar != nil && $0.isVisible })
                else { return }
                window.setFrame(NSRect(x: 60, y: 200, width: width, height: 760), display: true)
                try? await Task.sleep(for: .milliseconds(1200))
                logToolbarState(window, requested: width, phase: "collapsed")

                model.toggleInspectorTab(.diff, for: workspace.id)
                try? await Task.sleep(for: .milliseconds(1200))
                logToolbarState(window, requested: width, phase: "diff")

                model.toggleInspectorTab(.browser, for: workspace.id)
                try? await Task.sleep(for: .milliseconds(1200))
                logToolbarState(window, requested: width, phase: "browser")

                model.toggleInspectorTab(.browser, for: workspace.id)
                try? await Task.sleep(for: .milliseconds(1200))
                logToolbarState(window, requested: width, phase: "recollapsed")
            }
            await probeWindowFloor()
        }
    }

    /// TEMPORARY diagnostic: drives every sidebar x inspector combination down to the
    /// window's floor and reports the room the terminal region is left with.
    private func probeWindowFloor() async {
        guard let window = NSApp.windows.first(where: { $0.toolbar != nil && $0.isVisible })
        else { return }
        for sidebarOpen in [true, false] {
            if !sidebarOpen {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                try? await Task.sleep(for: .milliseconds(900))
            }
            for tab in [nil, InspectorTab.diff, .browser] as [InspectorTab?] {
                await setInspector(tab)
                // `setFrame` bypasses `contentMinSize` (it constrains user drags, not
                // programmatic sizing), so drive the window TO the floor instead and
                // measure there — the state a drag would come to rest in.
                window.setContentSize(window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(1000))
                window.setContentSize(window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(1000))
                let metrics = model.terminalHostMetrics
                let terminal = CGSize(
                    width: (detailFrame?.width ?? 0) - (metrics?.inspectorSlice ?? 0),
                    height: (detailFrame?.height ?? 0) - Self.paneDividerHeight)
                CasperLog.app.debug(
                    """
                    TIERPROBE FLOOR sidebar=\(sidebarOpen ? "open" : "collapsed", privacy: .public) \
                    tab=\(tab.map(String.init(describing:)) ?? "collapsed", privacy: .public) \
                    window=\(window.frame.width, privacy: .public)x\(window.frame.height, privacy: .public) \
                    contentMin=\(window.contentMinSize.width, privacy: .public)x\
                    \(window.contentMinSize.height, privacy: .public) \
                    minSize=\(window.minSize.width, privacy: .public)x\
                    \(window.minSize.height, privacy: .public) \
                    terminal=\(terminal.width, privacy: .public)x\(terminal.height, privacy: .public)
                    """)
            }
            if !sidebarOpen {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    /// Drives the inspector to an explicit state through the same mutator the UI uses.
    private func setInspector(_ tab: InspectorTab?) async {
        for _ in 0..<3 {
            guard let current = model.workspace(id: workspace.id) else { return }
            let showing: InspectorTab? = current.inspector.collapsed ? nil : current.inspector.tab
            if showing == tab { return }
            model.toggleInspectorTab(tab ?? current.inspector.tab, for: workspace.id)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func logToolbarState(_ window: NSWindow, requested: Double, phase: String) {
        guard let toolbar = window.toolbar else { return }
        let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
        let ours = toolbar.items
            .filter { UUID(uuidString: $0.itemIdentifier.rawValue) != nil }
            .map { item in
                let w = item.view.map { "\($0.frame.width)" } ?? "-"
                return "\(visible.contains(item.itemIdentifier.rawValue) ? "V" : "OVF"):\(w)"
            }
        var chevrons: [String] = []
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            if name.contains("Clipped") || name.contains("Overflow") {
                chevrons.append("\(name) hidden=\(view.isHidden) w=\(view.frame.width)")
            }
            view.subviews.forEach(walk)
        }
        if let themeFrame = window.contentView?.superview { walk(themeFrame) }
        let overflowed = toolbar.items
            .filter { !visible.contains($0.itemIdentifier.rawValue) }
            .map(\.itemIdentifier.rawValue)
        let detail = detailFrame?.debugDescription ?? "nil"
        CasperLog.app.debug(
            """
            TIERPROBE SWEEP want=\(requested, privacy: .public) phase=\(phase, privacy: .public) \
            got=\(window.frame.width, privacy: .public) \
            detail=\(detail, privacy: .public) row=\(self.rowWidth, privacy: .public) \
            items=\(toolbar.items.count, privacy: .public) \
            visible=\(toolbar.visibleItems?.count ?? -1, privacy: .public) \
            ours=[\(ours.joined(separator: ","), privacy: .public)] \
            overflowed=[\(overflowed.joined(separator: ","), privacy: .public)] \
            chevron=\(chevrons.isEmpty ? "no" : "YES", privacy: .public)
            """)
    }
    #endif

    /// Recompute the diff summary, cancelling any refresh still in flight. Every
    /// refresh — the first one included — goes through this single task, so
    /// overlapping revisions can't race to settle `diff` on a stale value.
    private func refreshDiffSummary() {
        diffSummaryTask?.cancel()
        diffSummaryTask = Task { @MainActor in
            let summary = await model.diffService.diffSummary(for: workspace)
            guard !Task.isCancelled else { return }
            diff = summary
        }
    }

    /// Whether the workspace shows more than one pane. True exactly when its root
    /// layout is a split: `LayoutTree` never builds a split with fewer than two
    /// children (it collapses a split down to its survivor when one is closed), so
    /// this needs no tree walk.
    static func hasMultiplePanes(in layout: LayoutNode) -> Bool {
        if case .split = layout { return true }
        return false
    }

    /// Allowed inspector-width range for the given container width: never below
    /// `InspectorState.minWidth`, never above `InspectorState.maxWidth`, and
    /// always leaving at least `minDetailWidth` for the detail area.
    private func inspectorRange(container: Double) -> ClosedRange<Double> {
        let upper = max(InspectorState.minWidth,
                        min(InspectorState.maxWidth, container - Self.minDetailWidth))
        return InspectorState.minWidth...upper
    }

    /// A self-drawn vertical divider (mirrors `SplitContainerView`'s splitter): the
    /// shared `SeparatorMetrics` line for layout, with the equally shared transparent
    /// grab strip overlaid on top — straddling the line and carrying the
    /// column-resize pointer — so the hit area never reserves visible layout width.
    /// Dragging it resizes the inspector; the model is persisted only on drag-end.
    private func inspectorDivider(total: Double, range: ClosedRange<Double>) -> some View {
        Rectangle()
            .fill(SeparatorMetrics.fill)
            .frame(width: SeparatorMetrics.visibleWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: SeparatorMetrics.grabWidth)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.inspectorDragSpace))
                            .onChanged { value in
                                // Track the pointer's ABSOLUTE x in the stable container space:
                                // the inspector's left edge sits at value.location.x, so its
                                // width is the space remaining to the right. Using the absolute
                                // location (not accumulated translation) keeps the divider
                                // locked to the pointer even as the panel — and this divider —
                                // shift during the drag, eliminating the resize lag.
                                inspectorWidth = (total - value.location.x).clamped(to: range)
                            }
                            .onEnded { _ in
                                if let width = inspectorWidth {
                                    model.setInspectorWidth(width, for: workspace.id)
                                }
                            })
            }
    }

    /// Gets the row back out of AppKit's overflow chevron, and keeps checking until
    /// it is out.
    ///
    /// One invalidation is enough for the common case, but not for every one: the
    /// content can change again while AppKit is still settling, and a row that stays
    /// in the chevron empties the whole title bar. So this re-checks, and re-checks
    /// only while the clipped-items indicator is actually on screen.
    ///
    /// The loop is broken three ways, which matters because the cure and the symptom
    /// share a mechanism: the retries stop the moment the indicator is gone, they are
    /// capped, and nothing here ever schedules itself from an invalidation — only an
    /// outside trigger starts a run.
    private static func healToolbarOverflow(retriesLeft: Int = 3) {
        invalidateToolbarItemSizes()
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSApp.windows.contains(where: { $0.isVisible && $0.hasClippedToolbarItems })
            else { return }
            healToolbarOverflow(retriesLeft: retriesLeft - 1)
        }
    }

    /// Tells AppKit that the toolbar items' sizes have changed.
    ///
    /// The row's width is always one pass behind the window: AppKit lays the toolbar
    /// out during the resize, while this row only learns its new width afterwards,
    /// from the detail area's geometry. When a shrink is large enough, AppKit
    /// therefore runs its fit check against the STALE, wider row, pushes the item
    /// into the overflow chevron — and never re-runs that check on its own, so the
    /// row stays in the chevron long after it has narrowed. That is not cosmetic:
    /// inside the chevron the chips lose their capsule chrome entirely.
    ///
    /// Measured on the running app at a 400 pt shrink jump: `validateVisibleItems()`
    /// changes nothing and neither does forcing the titlebar to lay out again;
    /// invalidating the item views' intrinsic size brings the row back immediately.
    /// Cheap enough to do unconditionally — a Casper window carries four items.
    private static func invalidateToolbarItemSizes() {
        for window in NSApp.windows where window.isVisible {
            window.toolbar?.items.forEach { $0.view?.invalidateIntrinsicContentSize() }
        }
    }

    /// Publishes what the window's floor is built from, and pushes that floor.
    ///
    /// Pushed from here rather than left to `WindowConfigurator`'s window observer
    /// alone: opening the inspector changes the floor without necessarily producing a
    /// window update, and a floor computed one state late is a floor the drag gets
    /// through.
    private func publish(_ metrics: TerminalHostMetrics?) {
        model.setTerminalHostMetrics(metrics)
        WindowFloor.apply(metrics)
    }

    /// What the window's floor is built from, or `nil` until the detail area has been
    /// measured. The inspector's slice is the width it OCCUPIES right now — the panel
    /// stays mounted at full width and is revealed by animating an outer clip, so the
    /// clip's width is the honest number and it is zero while collapsed.
    private var terminalHostMetrics: TerminalHostMetrics? {
        guard let detailFrame else { return nil }
        let inspectorSlice = workspace.inspector.collapsed
            ? 0
            : SeparatorMetrics.visibleWidth + (inspectorWidth ?? workspace.inspector.width)
                .clamped(to: inspectorRange(container: detailFrame.width))
        // Collapsed reads as a true zero; open never reads below the column minimum
        // (see `TerminalHostMetrics.sidebarWidth`).
        let sidebarWidth = detailFrame.minX < 1
            ? 0
            : max(detailFrame.minX, Self.sidebarColumnMinimum)
        return TerminalHostMetrics(
            sidebarWidth: sidebarWidth,
            inspectorSlice: inspectorSlice,
            detailChromeHeight: Self.paneDividerHeight)
    }

    /// The sidebar column's own minimum, mirroring `RootView`'s
    /// `.navigationSplitViewColumnWidth(min: 220, ...)`.
    private static let sidebarColumnMinimum: CGFloat = 220

    /// The `Divider()` above the pane tree, which is part of the detail area's height
    /// but not part of the terminal.
    private static let paneDividerHeight: CGFloat = 1

    /// The width the title bar has for this row.
    ///
    /// The detail area is ordinary in-window content, so it measures reliably —
    /// unlike anything read back from the toolbar itself. Everything else about the
    /// row's layout is then decided by the `HStack` from this one number.
    private var rowWidth: CGFloat {
        guard let detailFrame else { return Self.unmeasuredRowWidth }
        let windowChrome = detailFrame.minX < 1 ? Self.windowChromeReserve : 0
        // Never negative: at a window narrower than the sidebar the detail area is a
        // few points wide, and a row wider than that would overflow.
        return max(0, detailFrame.width - windowChrome - Self.safetyMargin)
    }
}

private extension NSWindow {
    /// Whether the toolbar is currently showing its clipped-items chevron.
    ///
    /// Read off the view tree because AppKit publishes no API for it, and
    /// `NSToolbar.visibleItems` cannot stand in: SwiftUI's own split-view separator
    /// item is absent from that collection at every width, chevron or not. A miss
    /// here (an OS that renames the class) costs one skipped retry, never a crash.
    var hasClippedToolbarItems: Bool {
        func containsIndicator(_ view: NSView) -> Bool {
            if String(describing: type(of: view)).contains("ClippedItemsIndicator") { return true }
            return view.subviews.contains(where: containsIndicator)
        }
        guard toolbar != nil, let themeFrame = contentView?.superview else { return false }
        return containsIndicator(themeFrame)
    }
}

/// The whole title bar, laid out in one row of a known width.
///
/// It is one view because it is one `ToolbarItem` (see the toolbar's own comment),
/// and it decides its own order of sacrifice as that width shrinks. Ranked by
/// layout priority, highest first:
///
/// 1. **the title group** (`2`) — the workspace's identity, which never drops. It
///    degrades on its own terms instead: the Space name goes whole, then the branch
///    middle-truncates.
/// 2. **the chips** (`1`) — they step down their own four-tier ladder rather than
///    disappear (see `WorkspaceToolbarActions`).
/// 3. **the diff badge** (`0`) — the first thing to go, before the chips even lose
///    their text. It is informational where the chips are actions, which is the
///    trade this ranking encodes.
/// 4. **the spacer** (`-1`) — below the badge on purpose: at an equal priority it
///    would swallow the room the badge needs and the badge would never appear.
///
/// The priorities are what make that order real, and they are independent of the
/// order the elements are written in — the badge still renders in its usual place,
/// between the info chip and the chips.
struct WorkspaceTitleBarRow: View {
    let model: AppModel
    let workspace: Workspace
    let diff: (insertions: Int, deletions: Int)?
    let width: CGFloat

    /// Report what the badge and the chips laid out to, so the row's layout tests can
    /// see which rung it settled on. A fixed-width stack tells an outside observer
    /// nothing about what is inside it, and the ladder's order — and its
    /// monotonicity — is precisely what needs pinning. Unused by the app.
    var onBadgeWidth: ((CGFloat) -> Void)?
    var onChipsWidth: ((CGFloat) -> Void)?

    var body: some View {
        // ONE ordered list for everything that yields. Every element that can give
        // way is a column of this table, and each rung gives up exactly one thing:
        //
        //   rung | title           | badge | actions
        //   -----+-----------------+-------+-------------------
        //    1   | Space / branch  |  yes  | full
        //    2   | Space / branch  |   -   | full
        //    3   | branch          |   -   | full
        //    4   | branch          |   -   | ( ⤭ )( ⋯ )
        //    5   | branch          |   -   | ( ⋯ )
        //    6   | branch          |   -   | ( ⋯ ), selector in its menu
        //
        // The order is what the pieces are FOR: the badge is informational, the
        // Space name is context, the chip labels are actions, and the branch is
        // identity — so they yield in that order and the branch never goes.
        //
        // One list rather than one ladder per element, because two ladders cannot be
        // ordered against each other: each sees only the room the other left it, so
        // whatever one releases the other takes back, and narrowing the window hands
        // an element its content RETURNED. Measured three times in this row before it
        // was one list — a badge that reappeared at 260 pt beside a folded chip, a
        // badge ranked by layout priority that came back the moment the chips folded,
        // and a selector that returned at 279 pt because the title had just dropped
        // its Space name and freed 90 pt.
        //
        // Within a rung the branch still middle-truncates. That is `Text` answering a
        // proposal — it changes how a rung looks, never which rung is chosen — so it
        // is not a second ladder.
        ViewThatFits(in: .horizontal) {
            rung(title: .spaceAndBranch, badge: true, chips: .full)
            rung(title: .spaceAndBranch, badge: false, chips: .full)
            rung(title: .branchOnly, badge: false, chips: .full)
            rung(title: .branchOnly, badge: false, chips: .mergeGlyph)
            rung(title: .branchOnly, badge: false, chips: .folded)
            rung(title: .branchOnly, badge: false, chips: .minimal)
        }
        // Giving the row a definite width is also what drives the ladder: it hands it
        // a real proposal, which a toolbar item on its own never does.
        .frame(width: width, alignment: .leading)
    }

    /// One rung, laid out left to right: title, badge, then the chips at the trailing
    /// edge.
    private func rung(
        title titleForm: WorkspaceTitleLabel.Form, badge: Bool,
        chips: WorkspaceToolbarActions.Density
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                title(titleForm)
                WorkspaceInfoButton(model: model, workspace: workspace)
            }
            // A group proposed less than its ideal width must truncate, never wrap:
            // without this the title pushes the title bar open instead of shortening
            // (see `WorkspaceTitleLabel` and the `toolbar-group-truncation` note).
            .lineLimit(1)
            // Served first, so the branch keeps its room and the chips are what give
            // way inside a rung.
            .layoutPriority(2)

            Group {
                if badge {
                    diffBadge
                }
            }
            // Both the badge and the chips are fixed at their ideal width inside a
            // rung, so a rung is all-or-nothing. Left flexible they compress instead:
            // `ViewThatFits` accepts a candidate that can squeeze its text, so the
            // chip labels would tighten a few points at a time and then spring back
            // to full width at the next rung — measured growing 253 -> 265 pt as the
            // row NARROWED past 601 pt. The title is the one thing that stays
            // flexible, because truncating the branch is what a rung is allowed to
            // do internally.
            .fixedSize(horizontal: true, vertical: false)
            // Fires with 0 on the rungs that drop the badge, which is what lets the
            // row's tests see that it went whole rather than shrank.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onBadgeWidth?($0) }

            Spacer(minLength: WorkspaceDetailView.chipGap)

            WorkspaceToolbarActions(model: model, workspace: workspace, density: chips)
                .fixedSize(horizontal: true, vertical: false)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    onChipsWidth?($0)
                }
        }
    }

    private func title(_ form: WorkspaceTitleLabel.Form) -> some View {
        // Resolve the owning Space once — `model.space(for:)` scans every Space's
        // workspaces, so both the git-backed flag and the name derive from this
        // single lookup rather than scanning the model twice per body pass.
        let space = model.space(for: workspace)
        return WorkspaceTitleLabel(
            isGitRepo: space?.isGitRepo ?? false,
            spaceName: space?.name ?? workspace.name,
            branchLabel: workspace.branchLabel,
            form: form)
        // Chrome-less on purpose: the title is not a control, so it keeps the
        // shared capsule metrics (alignment with the chips) without the pill.
        // Asymmetric interior padding (not the shared `titleCapsule`'s symmetric
        // 10 pt): the leading edge still owes its distance to the window edge,
        // while the trailing edge is tuned so the title-to-glyph gap (this
        // inset + the info button's own 2 pt inner padding) matches the
        // glyph-to-badge gap on the other side of the info chip.
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .titleCapsuleShell(filled: false)
    }

    @ViewBuilder private var diffBadge: some View {
        if let summary = visibleDiffSummary {
            Button {
                model.toggleInspectorTab(.diff, for: workspace.id)
            } label: {
                diffCounters(summary)
                    .titleCapsule(interactive: true)
            }
            .buttonStyle(.plain)
            .help("Toggle diff")
        }
    }

    /// The summary the badge renders, or `nil` when there is nothing to show.
    private var visibleDiffSummary: (insertions: Int, deletions: Int)? {
        guard let diff, diff.insertions > 0 || diff.deletions > 0 else { return nil }
        return diff
    }

    /// The badge's two counters.
    private func diffCounters(_ summary: (insertions: Int, deletions: Int)) -> some View {
        HStack(spacing: 5) {
            Text("+\(summary.insertions)").foregroundStyle(DiffLineStyle.insertionTint.opacity(0.9))
            Text("−\(summary.deletions)").foregroundStyle(DiffLineStyle.deletionTint.opacity(0.9))
        }
        .font(.body.monospacedDigit().bold())
    }
}


/// Every trailing title-bar chip, in one row that gives way as the window narrows:
/// Merge, Run Script, Editor and the Diff / Browser selector.
///
/// - `.full` — every chip with its text:
///   `( ⤭ Merge )( ▶ Run )( icon VS Code ⌄)( ± | 🌐 )`.
/// - `.mergeGlyph` — Merge keeps a chip of its own, as a glyph; Run and Editor move
///   into the `⋯` menu: `( ⤭ )( ⋯ )( ± | 🌐 )`. Merge is the one action worth a chip
///   at this width, and Run and Editor have no glyph-only form on the bar at all —
///   they go from their full text form straight into the menu, because an icon alone
///   names neither "which script" nor "which editor" the way their labels do.
/// - `.folded` — Merge joins them: `( ⋯ )( ± | 🌐 )`.
/// - `.minimal` — the `⋯` chip alone, the selector's two toggles moving into its
///   menu. The floor, so the ladder still terminates in something that fits at the
///   narrowest window AppKit allows.
///
/// The point of the ladder is that AppKit's own toolbar overflow is never reached:
/// the custom SwiftUI chips render without their capsule chrome inside that
/// popover, and the segmented control clips to a lone glyph. Overflow is also why
/// the selector lives here rather than in a `ToolbarItem` of its own — AppKit can
/// only overflow an item it can single out.
///
/// Internal rather than private so `WorkspaceToolbarActionsTests` can host it and
/// measure each tier — same reason as `InspectorTabSelector`.
struct WorkspaceToolbarActions: View {
    /// The four tiers, widest first. Named for the row each one draws.
    enum Density: CaseIterable {
        /// Every chip with its text.
        case full
        /// Merge as a glyph chip beside the `⋯` menu that holds Run and Editor.
        case mergeGlyph
        /// One `⋯` chip and the selector.
        case folded
        /// The `⋯` chip alone.
        case minimal
    }

    let model: AppModel
    let workspace: Workspace
    /// Which tier to draw. Chosen by `WorkspaceTitleBarRow`, never here: the choice
    /// has to be made together with the diff badge's, or the two ladders disagree.
    let density: Density

    var body: some View {
        // Observe the scripts revision: the Run Script visibility gate, its menu
        // list and the resolved default are all read in this body, and the cache
        // behind `namedCommands(for:)` is `@ObservationIgnored`, so a live
        // `.casper.json` change reaches them only through the revision. Read here
        // rather than in `WorkspaceDetailView` so a script change re-renders this
        // row alone — the same scoping `MergeToolbarButton` uses for `optionKeyHeld`.
        let _ = model.scriptsRevision
        // Every chip label stays on ONE line. The row hands the chips a definite
        // width, and a `Text` given less than it wants answers by WRAPPING — mid-word
        // — which would push the title bar open instead of shortening (the failure
        // the `toolbar-group-truncation` note describes). A chip is a fixed-height
        // capsule, so a second line has nowhere to go.
        return row(density).lineLimit(1)
    }

    /// One tier, drawn. Non-private so the tests can measure each tier directly
    /// rather than inferring which one the row picked.
    @ViewBuilder
    func row(_ density: Density) -> some View {
        HStack(spacing: WorkspaceDetailView.chipGap) {
            switch density {
            case .full:
                if canMerge {
                    MergeToolbarButton(model: model, workspace: workspace, density: density)
                }
                if hasScripts {
                    ScriptToolbarButton(model: model, workspace: workspace)
                }
                if hasEditors {
                    editorChip
                }
            case .mergeGlyph:
                if canMerge {
                    MergeToolbarButton(model: model, workspace: workspace, density: density)
                }
                foldedChip(density)
            case .folded, .minimal:
                // Always drawn, whatever the action gates say: at these tiers the chip
                // is the only route to the actions it holds.
                foldedChip(density)
            }
            if Self.showsInspectorSelector(at: density) {
                InspectorTabSelector(model: model, workspace: workspace)
            }
        }
    }

    /// Whether the Diff / Browser control rides on the bar at `density`.
    ///
    /// The single source for that fact: the `⋯` menu's `Sidebar` entry is exactly its
    /// complement, so the control is reachable at every tier and duplicated at none.
    /// Read by the row and by the menu, which is what keeps the two from drifting —
    /// a menu listing what is already on the bar is the one thing the `⋯` chip must
    /// never do.
    static func showsInspectorSelector(at density: Density) -> Bool { density != .minimal }

    /// Whether this workspace can be merged into its recorded base branch: only a
    /// linked worktree that records one has anywhere to merge to. Mirrors the
    /// menus' `canCloseSelectedWorkspace` gate, but derives from the workspace this
    /// row renders instead of the model's selection — the toolbar always acts on
    /// the workspace it is drawn for, which this view already holds.
    private var canMerge: Bool {
        workspace.kind == .linked && !(workspace.baseBranch?.isEmpty ?? true)
    }

    private var hasScripts: Bool { !model.namedCommands(for: workspace.id).isEmpty }

    private var hasEditors: Bool { !model.availableEditors.isEmpty }

    /// Text form only, for the same reason as the Run chip: an app icon alone does
    /// not say which editor will open, and the tier below lists them all by name in
    /// the `⋯` menu.
    private var editorChip: some View {
        let current = model.resolvedEditor(nil, for: workspace)
        return TitleSplitButton {
            model.openInEditor(nil, for: workspace.id)
        } primaryLabel: {
            if let current {
                editorLabel(current)
            } else {
                Text("Editor")
            }
        } menuContent: {
            ForEach(model.availableEditors, id: \.self) { kind in
                Button {
                    model.selectEditor(kind, for: workspace.id)
                } label: {
                    editorLabel(kind)
                }
            }
        }
        .help("Open in Editor")
        .accessibilityLabel("Open in Editor")
    }

    @ViewBuilder
    private func editorLabel(_ kind: EditorKind) -> some View {
        if let icon = EditorLauncher.icon(for: kind) {
            Label { Text(kind.displayName) } icon: { Image(nsImage: icon) }
        } else {
            Text(kind.displayName)
        }
    }

    /// The `⋯` chip: every action the row can no longer show, behind one menu. At
    /// `.minimal` it also carries the Diff / Browser toggles, which have no
    /// segmented control left to live in.
    ///
    /// `.menuStyle(.button)` + `.buttonStyle(.plain)` rather than the split
    /// buttons' `.borderlessButton`, so the capsule can live INSIDE the label and
    /// the whole pill stays clickable (see the `title-capsule-hit-area` note). A
    /// borderless menu ignores its label's height and keeps its click target on
    /// the bare glyph, which measured 20×14 against this chip's 34×36. The chrome
    /// stays the explicit fill + hairline border — never glass, which renders
    /// nearly invisible around a nested `Menu`
    /// (`glasseffect-nested-menu-invisible`).
    private func foldedChip(_ density: Density) -> some View {
        Menu {
            foldedMenuContent(density)
        } label: {
            Image(systemName: "ellipsis")
                .glyphSlot()
                .titleCapsule(interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // The plain button style draws no disclosure chevron of its own; this
        // keeps it that way if the menu style is ever revisited — a `⋯` chip must
        // not carry an indicator.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    /// The `⋯` menu lists exactly what the bar cannot show, in the SAME order the
    /// chips appear in — Merge, Run Script, Editor, then the inspector — so the
    /// folded form reads like the row it stands in for. The two orders are coupled:
    /// changing one means changing the other.
    ///
    /// Its contents therefore vary by tier, and never duplicate a chip that is still
    /// on the bar: at `.mergeGlyph` the Merge chip is right beside it, so the menu
    /// opens on Run Script, and `Sidebar` appears only once the segmented control has
    /// folded in here too.
    @ViewBuilder
    private func foldedMenuContent(_ density: Density) -> some View {
        // Merge has its own chip at `.mergeGlyph`; below that it lives here.
        if canMerge, density != .mergeGlyph {
            // The chip's Option-held Merge → Delete swap is not reproduced here:
            // a menu has room for both at once, so there is nothing to disambiguate
            // with a modifier.
            Button("Merge and Close Workspace…") {
                model.presentCloseWorkspaceConfirmation(id: workspace.id)
            }
            Button("Delete Workspace…") {
                model.presentDeleteWorkspaceConfirmation(id: workspace.id)
            }
            // The destructive pair is the only group set apart; the three submenus
            // below read as one list.
            Divider()
        }
        if hasScripts {
            Menu("Run Script") {
                // These items RUN the script, unlike the split button's menu, which
                // only selects the one its primary action will run: a menu has no
                // primary action, so selecting without running would do nothing.
                ForEach(model.namedCommands(for: workspace.id), id: \.name) { command in
                    Button(command.displayName) {
                        model.runScript(command.name, for: workspace.id)
                    }
                }
            }
        }
        if hasEditors {
            Menu("Open in Editor") {
                ForEach(model.availableEditors, id: \.self) { kind in
                    Button {
                        model.openInEditor(kind, for: workspace.id)
                    } label: {
                        editorLabel(kind)
                    }
                }
            }
        }
        // Named for the panel it drives — the inspector panel on the right, not the
        // workspace column on the left that the toolbar's own sidebar toggle opens.
        if !Self.showsInspectorSelector(at: density) {
            Menu("Sidebar") {
                inspectorTabItems
            }
        }
    }

    /// The Diff / Browser toggles as menu items, for the tier that has no room left
    /// for the segmented control. They route through the very same mutator the
    /// segments use, so the three states the control makes visible survive the
    /// fold: a checkmark marks the tab currently showing, and neither is marked
    /// while the panel is collapsed.
    @ViewBuilder
    private var inspectorTabItems: some View {
        let showing: InspectorTab? = workspace.inspector.collapsed ? nil : workspace.inspector.tab
        inspectorTabItem(.diff, title: "Toggle Diff", showing: showing)
        inspectorTabItem(.browser, title: "Toggle Browser", showing: showing)
    }

    @ViewBuilder
    private func inspectorTabItem(_ tab: InspectorTab, title: String,
                                  showing: InspectorTab?) -> some View {
        Button {
            model.toggleInspectorTab(tab, for: workspace.id)
        } label: {
            if showing == tab {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// The title-bar Diff / Browser control: one capsule enclosing both glyph-only
/// segments, with a single indicator that slides from one to the other. Rendering
/// them as one segmented control — rather than as two identical pills — is what
/// makes it legible that at most one tab can be on.
///
/// Three states are visible: the panel open on Diff, open on Browser, and
/// collapsed. Collapsed draws NO indicator at all, so "neither is on" reads as
/// distinct from either selection.
///
/// Each segment routes through `toggleInspectorTab`, which expands onto its tab
/// when the panel is collapsed, collapses the panel when it is already open on
/// that tab, and otherwise just switches tab.
///
/// Geometry follows the `title-capsule-hit-area` memory note: the shell wraps the
/// whole `HStack`, and the interior padding lives inside each `Button`'s label so
/// both halves of the pill are clickable rather than just the glyphs.
///
/// Internal rather than private so `InspectorTabSelectorTests` can host it.
struct InspectorTabSelector: View {
    /// Each segment is one glyph chip wide, from the shared metrics: the sliding
    /// indicator would otherwise change size as it moved between two symbols of
    /// different widths, and the segments would not match the chips beside them.

    /// The width this control always lays out to — two identical segments, and the
    /// capsule shell adds nothing around them.
    ///
    /// Exposed so the row's layout tests can assert against the control they
    /// describe: it rides in every tier but the last, so its width is part of what
    /// each of those tiers costs. `InspectorTabSelectorTests` pins it against the
    /// hosted control so the two cannot drift apart.
    static let intrinsicWidth: CGFloat = 2 * TitleCapsuleMetrics.glyphChipWidth

    let model: AppModel
    let workspace: Workspace

    /// Anchors the one selection indicator so it slides horizontally between the
    /// segments instead of cross-fading.
    @Namespace private var selectionNamespace

    var body: some View {
        // `nil` while the panel is collapsed — the "neither is on" state.
        let selection: InspectorTab? = workspace.inspector.collapsed ? nil : workspace.inspector.tab
        return HStack(spacing: 0) {
            segment(.diff, systemImage: "plusminus", help: "Toggle diff", selection: selection)
            segment(.browser, systemImage: "globe", help: "Toggle browser", selection: selection)
        }
        .titleCapsuleShell(interactive: true)
        // One value covering both which tab is selected and whether the panel is
        // collapsed, so the indicator animates on either change.
        .animation(.smooth(duration: 0.22), value: selection)
    }

    /// One glyph-only segment. `help` names it for both the tooltip and VoiceOver.
    private func segment(_ tab: InspectorTab, systemImage: String, help: String,
                         selection: InspectorTab?) -> some View {
        let isSelected = selection == tab
        return Button {
            model.toggleInspectorTab(tab, for: workspace.id)
        } label: {
            Image(systemName: systemImage)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                // The fixed slot goes INSIDE the padding so the insets still widen
                // the segment (see the `fixed-frame-swallows-inner-padding` memory
                // note) and the whole pill half stays clickable.
                .glyphSlot()
                .padding(.horizontal, TitleCapsuleMetrics.horizontalInset)
                .frame(maxHeight: .infinity)
                // The indicator exists only behind the selected segment and is
                // matched across the two, so it slides rather than cross-fades.
                // Per-segment hover is deliberately absent: the shell already
                // lights up as a whole, as the Run / Editor pills do.
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color(nsColor: .controlColor))
                            .padding(3)
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selectedTab", in: selectionNamespace, isSource: true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A title-bar split button: a primary `Button` and a borderless `Menu` sharing
/// one capsule shell, as used by the Run Script and Editor chips.
///
/// The geometry is the load-bearing part (see the `title-capsule-hit-area` memory
/// note). The capsule SHELL wraps the WHOLE `HStack` so it is one visible shape
/// enclosing both controls: a `Menu` renders its disclosure chevron OUTSIDE its
/// label view, so styling only the label never produces an enclosing pill. The
/// capsule's interior insets therefore live INSIDE each control's label rather than
/// on the shell — no child can reach into the shell's own padding — which is what
/// makes the whole pill clickable instead of just the glyph/text. The primary
/// button takes no `maxWidth`, so it stays content-sized and never stretches the
/// toolbar.
private struct TitleSplitButton<PrimaryLabel: View, MenuContent: View>: View {
    let action: () -> Void
    @ViewBuilder let primaryLabel: () -> PrimaryLabel
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                primaryLabel()
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu(content: menuContent) {
                // .menuStyle(.borderlessButton) always appends its own disclosure chevron
                // after the label, so a label chevron here would render twice (⌄⌄). Keep
                // the label empty and let the style's own arrow be the only visible one.
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Fill the capsule's right inset so its trailing edge isn't a dead zone.
            .padding(.trailing, 10)
        }
        .titleCapsuleShell(interactive: true)
    }
}

/// The "Run Script" toolbar split-button. It holds no state of its own; it stays a
/// separate view to keep the toolbar item's body readable and to scope the script
/// observation reads (`namedCommands`, `resolvedScript`) to the chip that draws
/// them.
private struct ScriptToolbarButton: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let commands = model.namedCommands(for: workspace.id)
        let current = model.resolvedScript(for: workspace)
        return TitleSplitButton {
            if let current { model.runScript(current.name, for: workspace.id) }
        } primaryLabel: {
            // Pinned explicitly: the toolbar environment resolves a `Label` icon-only
            // on its own and would drop the title (see the `toolbar-label-style`
            // note) — and the title is the whole point of this chip. Which script it
            // will run is exactly what the glyph cannot say, so there is no
            // glyph-only form of it on the bar: the tier below moves it into the `⋯`
            // menu, where every command is listed by name.
            Label(current?.displayName ?? "Run", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
        } menuContent: {
            ForEach(commands, id: \.name) { command in
                Button {
                    model.selectScript(command.name, for: workspace.id)
                } label: {
                    if command.name == current?.name {
                        Label(command.displayName, systemImage: "checkmark")
                    } else {
                        Text(command.displayName)
                    }
                }
            }
        }
        .help("Run Script")
        .accessibilityLabel("Run Script")
    }
}

/// Internal rather than private so the row's tests can host it: the Merge/Delete
/// swap has to be pinned at equal width, and that is invisible from outside the row.
struct MergeToolbarButton: View {
    let model: AppModel
    let workspace: Workspace
    let density: WorkspaceToolbarActions.Density

    var body: some View {
        // Read here rather than in `WorkspaceDetailView`: the observation dependency
        // that re-renders the chip on every Option press and release is registered by
        // reading the property inside the body that draws it.
        let deleting = model.optionKeyHeld
        let help = deleting ? "Delete workspace" : "Merge and close workspace"
        return Button {
            if deleting {
                model.presentDeleteWorkspaceConfirmation(id: workspace.id)
            } else {
                model.presentCloseWorkspaceConfirmation(id: workspace.id)
            }
        } label: {
            let label = Label(deleting ? "Delete" : "Merge",
                              systemImage: deleting ? "trash" : "arrow.triangle.merge")
            Group {
                // Both styles are pinned explicitly: the toolbar environment's own
                // default is icon-only, so leaving it to that would drop the title at
                // `.full`, and it is not what the glyph tier should lean on either.
                if density == .full {
                    label.labelStyle(.titleAndIcon)
                } else {
                    // The shared slot is what keeps Merge and Delete the same size:
                    // `trash` is 3 pt wider than `arrow.triangle.merge`, so without it
                    // the chip would resize the instant Option is held — under a
                    // stationary pointer, which is exactly when a size change reads as
                    // a different control appearing.
                    label.labelStyle(.iconOnly).glyphSlot()
                }
            }
            // The capsule geometry stays INSIDE the label in both forms, so the whole
            // pill keeps firing the action rather than just the glyph.
            .titleCapsule(interactive: true)
        }
        .buttonStyle(.plain)
        .help(help)
        // In the glyph form the tooltip is the only thing naming the action, and it
        // names the action the click will actually perform.
        .accessibilityLabel(help)
    }
}

/// The metrics every title-bar chip shares.
///
/// A named constant rather than a literal per call site so the layout tests can
/// assert the chips still lay out as one row against the very number the chrome
/// applies.
enum TitleCapsuleMetrics {
    static let height: CGFloat = 36

    /// The capsule's interior horizontal inset.
    static let horizontalInset: CGFloat = 10

    /// The slot every glyph-only chip reserves for its glyph.
    ///
    /// Fixed on purpose: SF Symbols carry different intrinsic widths, so chips sized
    /// to their content come out uneven — measured, `arrow.triangle.merge` and
    /// `play.fill` are 12 pt against `trash` and `globe` at 15 and
    /// `square.and.pencil` at 16. A row of glyph-only chips is a row of identical
    /// pills; one wider than its neighbours reads as a different KIND of control
    /// rather than as the same control shortened. The slot makes them identical by
    /// construction rather than by two symbols happening to agree.
    ///
    /// Sized from the `⋯` chip, which is the reference dimension for the set, then
    /// widened to clear the widest glyph that has to sit in it — so every chip
    /// widened together and they stayed identical. Roomier than that widest glyph on
    /// purpose: a slightly generous chip looks fine, an overflowing one does not.
    static let glyphSlotWidth: CGFloat = 18

    /// The width every glyph-only chip lays out to, `⋯` included.
    static let glyphChipWidth: CGFloat = glyphSlotWidth + 2 * horizontalInset
}

/// The capsule chrome itself — fixed height, fill, hairline border, hit shape —
/// plus the hover highlight that makes an interactive chip read as clickable.
///
/// It lives in a `ViewModifier` (rather than as `.onHover` on each call site) for
/// the `@State` it needs, and because sitting on the shell makes hover cover the
/// WHOLE pill, including the nested borderless `Menu` chevron of the split
/// buttons — a per-control `.onHover` would flicker as the pointer crosses them.
private struct TitleCapsuleChrome: ViewModifier {
    let filled: Bool
    /// Buttons opt in; the branch/space `title` chip is not clickable, so it stays
    /// hover-inert and renders exactly as it did before hover existed.
    let interactive: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hovering = false

    private var highlighted: Bool { interactive && hovering }

    /// Native toolbar controls dim when the window stops being key/main, so the
    /// interactive chips dim with them. Fading the whole shell keeps the glyphs,
    /// the +N/−N tints and the capsule in step, and opacity alone can never shift
    /// the layout.
    private var shellOpacity: Double { controlActiveState == .inactive ? 0.5 : 1 }

    /// An unfilled chip grows the standard fill + border on hover, so the capsule
    /// "appears" like a native toolbar button. Padding, height and hit area are
    /// already identical in both states, so this can never shift the layout.
    private var showsChrome: Bool { filled || highlighted }

    private var fill: Color {
        guard showsChrome else { return .clear }
        // Same step in both palettes.
        return Color.secondary.opacity(highlighted ? 0.28 : 0.15)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shell = content
            .frame(height: TitleCapsuleMetrics.height)
            .background(fill, in: Capsule())
            .overlay(showsChrome ? Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5) : nil)
            .contentShape(Capsule())

        if interactive {
            shell
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .opacity(shellOpacity)
                .animation(.easeOut(duration: 0.12), value: controlActiveState)
        } else {
            shell
        }
    }
}

private extension View {
    /// The one shared title-bar capsule chrome. Every title-bar chip uses this so
    /// they render strictly identically. Explicit fill + hairline border (not
    /// Liquid Glass) because glass renders nearly invisible on chips that embed a
    /// nested borderless `Menu` (Run / Editor), so this is the only treatment that
    /// works for every chip.
    ///
    /// Pass `filled: false` to drop the fill and border while keeping the exact
    /// same padding, height, and hit area. Used by the branch/space `title`, which
    /// reads as a label rather than a chip yet still lines up with the chips next
    /// to it.
    ///
    /// Pass `interactive: true` for chips that are buttons, so they light up on
    /// hover like a native toolbar button; see `TitleCapsuleChrome`.
    func titleCapsule(filled: Bool = true, interactive: Bool = false) -> some View {
        self
            .padding(.horizontal, TitleCapsuleMetrics.horizontalInset)
            .titleCapsuleShell(filled: filled, interactive: interactive)
    }

    /// Reserves the shared glyph slot, so every glyph-only chip is the same width
    /// whatever symbol it draws.
    ///
    /// Goes INSIDE the capsule's padding (see the `fixed-frame-swallows-inner-padding`
    /// note): the insets still widen the pill around it, and the whole pill stays
    /// clickable rather than just the glyph.
    func glyphSlot() -> some View {
        frame(width: TitleCapsuleMetrics.glyphSlotWidth)
    }

    /// The capsule chrome WITHOUT the interior horizontal padding. Split out from
    /// `titleCapsule` so a split-button (Run / Editor) can wrap the whole HStack in
    /// the visible pill while its inner controls carry the padding themselves —
    /// keeping that padding inside their clickable label instead of as dead
    /// decoration around a `.plain` button (see the `title-capsule-hit-area`
    /// memory note). `interactive` behaves as in `titleCapsule`.
    func titleCapsuleShell(filled: Bool = true, interactive: Bool = false) -> some View {
        modifier(TitleCapsuleChrome(filled: filled, interactive: interactive))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension ToolbarContent {
    /// Removes the automatic macOS 26 "Liquid Glass" capsule background that wraps
    /// toolbar item content, so the diff badge can draw its OWN distinct glass
    /// capsule instead of merging into the branch capsule's shared glass.
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
