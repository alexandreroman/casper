import AppKit
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

    /// The divider drag's live inspector width, and `nil` until a drag — the panel
    /// reads the persisted `workspace.inspector.width` until then. Persisted on
    /// drag-end and held locally so the drag never mutates observed model state
    /// mid-layout. The per-workspace `.id` `RootView` gives this view is what keeps
    /// one workspace's drag from leaking into the next.
    @State private var inspectorWidth: Double?

    /// True for the length of a divider drag, which suspends `publish`.
    ///
    /// The window's floor is a function of the inspector's width, so without this a
    /// drag rewrites every window's minimum size on every frame — and, because
    /// `WindowFloor.apply` also grows a window that has fallen under its floor, a
    /// window already resting on that floor is resized to match on every frame too,
    /// chasing the pointer across the screen. The floor is therefore deferred to
    /// drag-end exactly as the model write already is: the width the drag comes to
    /// rest at is the only one the floor has to be right for.
    @State private var isDraggingInspector = false

    /// The detail area's frame in window coordinates, or `nil` until the first
    /// layout pass has measured it. `nil` means "not measured yet", which the chip
    /// row must read as roomy: a row that started out folded and unfolded a frame
    /// later would flicker on every workspace switch.
    @State private var detailFrame: CGRect?

    /// Extra undershoot on the row's width while the window is being dragged
    /// narrower, decided pass by pass by `nextUndershoot(current:shrink:isLiveResize:)`.
    ///
    /// It costs the settled row nothing only once it has been released, which is later
    /// than a single pass: the ratchet holds it through the growing half of a reversed
    /// drag, and the re-arming debounce holds it while the pointer is kept still
    /// mid-drag. See `rowWidth(detailFrame:undershoot:isFullScreen:)` for what it buys and
    /// `scheduleUndershootRelease` for how it is given back.
    @State private var resizeUndershoot: CGFloat = 0

    /// The pending release of `resizeUndershoot`, and `nil` when none is pending. At
    /// most one exists at a time, so only one release can fire per drag — see
    /// `scheduleUndershootRelease`.
    @State private var undershootReleaseTask: Task<Void, Never>?

    /// Whether the workspace window is in full screen, which picks the chrome reserve
    /// `rowWidth` charges with the sidebar collapsed.
    ///
    /// Flipped asymmetrically so the row always errs to the larger reserve, for the
    /// same reason `safetyMargin` exists: too narrow costs a few invisible points, too
    /// wide sends the whole row into the chevron. So it turns true only once the window
    /// HAS entered full screen, and false as soon as it is ABOUT to leave — before the
    /// traffic lights come back into the row.
    @State private var isFullScreen = false

    #if DEBUG
    /// The ladder rung the row last reported, for the passive resize trace and for
    /// nothing else. `nil` until the row has laid out once, and left `nil` for the
    /// whole session unless the trace was armed — see `traceRungHook`.
    @State private var tracedRung: TitleBarRung?
    #endif

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

    /// `windowChromeReserve` for a window in full screen, where the traffic lights
    /// leave the toolbar and only the sidebar toggle is left sharing the row.
    ///
    /// Measured on the same `NSWindow` + `NSToolbar` taken full screen, whose toolbar
    /// then lives in an `NSToolbarFullScreenWindow`: the toggle's viewer starts at
    /// x = 6 instead of 92, still 48 pt wide. 6 + 48 = 54, i.e. the traffic lights
    /// cost exactly 86 pt.
    static let fullScreenChromeReserve: CGFloat = 54

    /// Standing undershoot on the row's width, applied at every width including a
    /// settled one.
    ///
    /// Sized to lose the race on purpose: a row a few points narrower than the bar
    /// leaves a sliver nobody notices at the trailing edge, while a row a few points
    /// wider overflows the ONE item that holds every title-bar control. It covers a
    /// still window only — AppKit's item viewer starts inside the detail area, which
    /// leaves about 16 pt of this as real slack (measured: app-ui.md § Title bar) —
    /// and `resizeUndershoot` covers a moving one, on top of this.
    static let safetyMargin: CGFloat = 24

    /// Narrowest row worth mounting. The `⋯` chip alone measures 38 pt, so below
    /// this there is nothing left to draw — and at such a width the detail area is
    /// a sliver anyway (a 320 pt window leaves it 22 pt beside the sidebar).
    ///
    /// The row is then dropped from the toolbar entirely rather than shown at a few
    /// points wide, because AppKit cannot fit ANY item into a bar that narrow and
    /// would answer with the overflow chevron. No item, nothing to overflow.
    static let minimumRowWidth: CGFloat = 40

    /// Ceiling on the resize undershoot, whatever the pass measured.
    ///
    /// SwiftUI coalesces layout passes during a fast drag, so a measured shrink is the
    /// whole distance travelled since the last pass, and unbounded: subtracted whole,
    /// one coalesced pass drives the row to `minimumRowWidth` (measured: app-ui.md
    /// § Title bar). 40 pt is twice the fastest ordinary pass (measured: 5–20 pt) and
    /// just under one `⋯` chip plus its gap (38 + `chipGap` = 46). A larger jump is
    /// left to the single frame of chevron `healToolbarOverflow` recovers, not to a
    /// collapsed row.
    static let maximumResizeUndershoot: CGFloat = 40

    /// How long the window must stand still before the row gives its resize
    /// undershoot back and unfolds to its exact width.
    ///
    /// A drag emits a geometry pass every frame (~16 ms at 60 Hz), so while the
    /// pointer keeps moving this is restarted long before it fires. A hand-driven drag
    /// is bursts of passes separated by pauses that outlast this delay, though, so
    /// firing is not on its own enough to conclude the drag is over — see
    /// `scheduleUndershootRelease`, which waits again while the resize is still live.
    ///
    /// The upper bound is perception: until it fires the row is narrower than the bar by
    /// the undershoot in force — at most `maximumResizeUndershoot`, whatever the drag
    /// was doing when it stopped — and that sliver of unused title bar must not be
    /// sitting there long enough to read as a misaligned row.
    private static let undershootSettleDelay: Duration = .milliseconds(150)

    /// Width the row takes while the detail area has not been measured yet.
    ///
    /// Small on purpose: unmeasured must mean NARROW. At this width the chips start
    /// folded and grow once the real width arrives, which costs at most one frame of
    /// a `⋯` chip — where starting wide would cost an overflowed row, and an
    /// overflowed row does not always come back on its own.
    static let unmeasuredRowWidth: CGFloat = 240

    var body: some View {
        GeometryReader { proxy in
            let range = inspectorRange(container: proxy.size.width)
            let width = inspectorPanelWidth(container: proxy.size.width)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    LayoutNodeView(
                        model: model, workspaceID: workspace.id, node: workspace.layout,
                        // The root is read only when it renders as a lone leaf.
                        canDragPanes: false)
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
                // approach. The divider's visible line lives inside the same
                // clipped container so it reveals with the panel rather than
                // popping in as a separate mount; only its grab strip sits
                // outside (see `inspectorGrabStrip`).
                HStack(spacing: 0) {
                    inspectorDividerLine
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: width)
                }
                .frame(width: inspectorSlice(container: proxy.size.width), alignment: .trailing)
                .clipped()
            }
            .overlay(alignment: .trailing) {
                inspectorGrabStrip(total: proxy.size.width, panelWidth: width, range: range)
            }
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recordDetailFrame($0) }
        // The window's floor is rebuilt from this, so it has to be republished when
        // the inspector moves as well as when the detail area does — the panes' share
        // is what is left after the panel takes its slice.
        .onChange(of: terminalHostMetrics) { _, metrics in publish(metrics) }
        .toolbar {
            // EVERY title-bar control lives in this ONE item, never wider than the bar:
            // AppKit overflows a toolbar item whole rather than shrinking it, so the row
            // does its own degrading inside it (see the
            // `toolbar-overflows-before-squeezing` note and app-ui.md § Title bar).
            if rowWidth >= Self.minimumRowWidth {
                ToolbarItem(placement: .navigation) {
                    WorkspaceTitleBarRow(
                        model: model, workspace: workspace, diff: diff, width: rowWidth)
                        #if DEBUG
                        // Passive observation, and only when it was asked for: with
                        // `CASPER_RESIZETRACE` unset the hook is nil, and the row then
                        // installs no reporter at all — it does not even name the rung
                        // it would have reported.
                        .reportingRung(traceRungHook)
                        #endif
                }
                .flatToolbarItem()
            }
        }
        .errorAlert("Couldn't Open Editor", message: Bindable(model).editorLaunchError)
        .errorAlert("Couldn't Run Script", message: Bindable(model).scriptRunError)
        // Re-runs AppKit's fit check whenever the width the row declares moves. The
        // inspector trigger is a deliberate safety net, not a second cause: the row's
        // definite `.frame(width:)` keeps its content from changing the width AppKit
        // measures (`testTogglingTheInspectorDoesNotChangeWhatTheRowLaysOut`), and an
        // inspector that makes `WindowFloor` grow the window moves `rowWidth` anyway.
        .onChange(of: rowWidth) { _, _ in Self.healToolbarOverflow() }
        .onChange(of: workspace.inspector) { _, _ in Self.healToolbarOverflow() }
        // Late on the way in, early on the way out — see `isFullScreen`. A flip moves
        // `rowWidth`, so the heal above re-runs AppKit's fit check on its own.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) {
            if Self.isToolbarWindow($0.object) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) {
            if Self.isToolbarWindow($0.object) { isFullScreen = false }
        }
        .onAppear {
            // `RootView` gives this view a per-workspace `.id`, so one instance only
            // ever renders one workspace — the first summary needs no keying.
            refreshDiffSummary()
            // Seeded here because each workspace switch builds a fresh instance, and
            // the app can launch straight into full screen: either way the
            // notifications above were posted before this view existed.
            isFullScreen = Self.workspaceWindow()?.styleMask.contains(.fullScreen) == true
            #if DEBUG
            // Layout harness — see `WorkspaceDetailView+ToolbarProbe.swift`. Inert
            // unless `CASPER_TIERPROBE_WIDTHS` or `CASPER_RESIZESTEP` asks for a sweep.
            startToolbarProbe { ToolbarProbeSample(detailFrame: detailFrame, rowWidth: rowWidth) }
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
            // Same reason: its only job is to write `@State` this instance no longer
            // has.
            undershootReleaseTask?.cancel()
            // Gated on "nothing is selected any more", not on this instance going
            // away. The detail view is keyed `.id(workspace.id)` (see `RootView`),
            // so switching workspaces tears one instance down while the incoming
            // one publishes its own geometry, and SwiftUI does not promise the
            // teardown runs first. A `nil` landing last would leave
            // `WindowConfigurator`'s window observer re-applying a zero floor to
            // every window until the next geometry change. Losing the last
            // workspace still clears the metrics, which is the case this is for.
            if model.selectedWorkspaceID == nil { publish(nil) }
        }
    }

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

    /// Allowed inspector-width range for the given container width: never below
    /// `InspectorState.minWidth`, never above `InspectorState.maxWidth`, and
    /// always leaving at least `minDetailWidth` for the detail area.
    private func inspectorRange(container: Double) -> ClosedRange<Double> {
        let upper = max(InspectorState.minWidth,
                        min(InspectorState.maxWidth, container - Self.minDetailWidth))
        return InspectorState.minWidth...upper
    }

    /// The inspector panel's own width for the given container width: the live
    /// drag's width if there is one, else the persisted one, clamped to
    /// `inspectorRange(container:)`.
    private func inspectorPanelWidth(container: Double) -> Double {
        (inspectorWidth ?? workspace.inspector.width).clamped(to: inspectorRange(container: container))
    }

    /// The width the whole inspector region — divider line plus panel — occupies, and
    /// 0 while the panel is collapsed.
    ///
    /// One function for both of its readers on purpose: this is the layout's clip
    /// width AND the slice the window's floor reserves (see `terminalHostMetrics`).
    /// Let the two drift apart and `WindowFloor.apply` grows the window against a
    /// slice the layout is not using.
    private func inspectorSlice(container: Double) -> CGFloat {
        guard !workspace.inspector.collapsed else { return 0 }
        return SeparatorMetrics.visibleWidth + inspectorPanelWidth(container: container)
    }

    /// The inspector divider's visible line: the shared `SeparatorMetrics` hairline,
    /// and nothing else.
    ///
    /// It stays inside the clipped inspector container so it is revealed and hidden
    /// with the panel. What resizes the inspector is a separate grab strip layered
    /// OUTSIDE that container — see `inspectorGrabStrip`.
    private var inspectorDividerLine: some View {
        Rectangle()
            .fill(SeparatorMetrics.fill)
            .frame(width: SeparatorMetrics.visibleWidth)
            .frame(maxHeight: .infinity)
    }

    /// The inspector divider's grab strip: the same AppKit `SplitterHandle` the
    /// terminal splits use, so both dividers are equally easy to catch.
    ///
    /// Layered on the full-width container rather than beside the line, because the
    /// inspector container is `.clipped()` and `.clipped()` clips HIT-TESTING as well
    /// as drawing: mounted in there, the half of the strip that straddles the
    /// terminal would be dead and only the panel-side half would answer. Out here the
    /// whole `SeparatorMetrics.grabWidth` is live, half over each side.
    ///
    /// A concrete `NSView` — not a SwiftUI `.pointerStyle` plus a `DragGesture` — is
    /// what makes the resize cursor win over the terminal surface's own
    /// `cursorUpdate` (see the terminal-overlay-cursor note). `SplitterHandleView`
    /// owns the cursor and the drag, tracking the pointer by absolute window movement
    /// from the boundary it snapshots at mouse-down.
    @ViewBuilder
    private func inspectorGrabStrip(
        total: Double, panelWidth: Double, range: ClosedRange<Double>
    ) -> some View {
        if !workspace.inspector.collapsed {
            SplitterHandle(
                orientation: .horizontal,
                // The boundary the drag reports back against: the panel's left edge,
                // matching the width formula below.
                boundary: total - panelWidth,
                onResize: { target in
                    isDraggingInspector = true
                    inspectorWidth = (total - target).clamped(to: range)
                },
                onCommit: {
                    isDraggingInspector = false
                    if let width = inspectorWidth {
                        model.setInspectorWidth(width, for: workspace.id)
                    }
                    // `terminalHostMetrics` settled while the publish was suspended,
                    // so `.onChange` has already fired for the final width and will
                    // not fire again.
                    publish(terminalHostMetrics)
                },
                // The terminal splits equalize on double-click; the inspector has no
                // equivalent, so a double-click does nothing.
                onEqualize: {})
                .frame(width: SeparatorMetrics.grabWidth)
                .frame(maxHeight: .infinity)
                // Centred on the line, whose own centre sits half a hairline to the
                // left of the panel's edge.
                .offset(x: -(panelWidth + SeparatorMetrics.visibleWidth / 2 - SeparatorMetrics.grabWidth / 2))
        }
    }

    /// Gets the row back out of AppKit's overflow chevron, and keeps checking until
    /// it is out.
    ///
    /// AppKit judges the width the row declared for the PREVIOUS layout pass and never
    /// re-runs that fit check on its own, so a row judged too wide stays in the
    /// chevron after it has narrowed — and inside it the chips lose their capsule
    /// chrome (see the `toolbar-overflows-before-squeezing` note). The resize
    /// undershoot anticipates every pass up to its cap; this takes back what it cannot:
    /// a wider pass, or a jump no previous pass could anticipate, such as collapsing the
    /// sidebar (see app-ui.md § Title bar).
    ///
    /// One invalidation is not always enough while AppKit is still settling, so this
    /// re-checks, and only while the clipped-items indicator is actually on screen.
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

    /// Tells AppKit that the toolbar items' sizes have changed, which is the one lever
    /// that re-runs its fit check: `validateVisibleItems()` and a forced titlebar
    /// layout change nothing (measured; see the `toolbar-overflows-before-squeezing`
    /// note). Cheap enough to do unconditionally — a Casper window carries four items.
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
    ///
    /// Suspended for the length of a divider drag — see `isDraggingInspector`, which
    /// also republishes once the drag ends. Every other trigger (a window resize, a
    /// workspace switch, the inspector collapsing or expanding) publishes as it did.
    private func publish(_ metrics: TerminalHostMetrics?) {
        guard !isDraggingInspector else { return }
        model.setTerminalHostMetrics(metrics)
        WindowFloor.apply(metrics)
    }

    /// What the window's floor is built from, or `nil` until the detail area has been
    /// measured. The inspector's slice is the width it OCCUPIES right now — the panel
    /// stays mounted at full width and is revealed by animating an outer clip, so the
    /// clip's width is the honest number and it is zero while collapsed.
    private var terminalHostMetrics: TerminalHostMetrics? {
        guard let detailFrame else { return nil }
        // Collapsed reads as a true zero; open never reads below the column minimum
        // (see `TerminalHostMetrics.sidebarWidth`).
        let sidebarWidth = detailFrame.minX < 1
            ? 0
            : max(detailFrame.minX, TerminalHostMetrics.sidebarColumnMinimum)
        return TerminalHostMetrics(
            sidebarWidth: sidebarWidth, inspectorSlice: inspectorSlice(container: detailFrame.width))
    }

    /// The `Divider()` above the pane tree, which is part of the detail area's height
    /// but not part of the terminal.
    static let paneDividerHeight: CGFloat = 1

    /// Records the frame this layout pass measured, along with the shrink it
    /// represents.
    ///
    /// `detailFrame` still holds the PREVIOUS pass's frame when this runs, which is
    /// the only reason the delta is available at all.
    private func recordDetailFrame(_ frame: CGRect) {
        let shrink = Self.shrink(previousWidth: detailFrame?.width, newWidth: frame.width)
        resizeUndershoot = Self.nextUndershoot(
            current: resizeUndershoot, shrink: shrink, isLiveResize: Self.isWindowInLiveResize)
        detailFrame = frame
        scheduleUndershootRelease()
        #if DEBUG
        // The trace's main sample: one line per pass that moved the detail area, which
        // during a drag is one line per frame. `delta=` is what the pass measured and
        // `undershoot=` what survived the cap and the ratchet, so the two differ on
        // exactly the passes worth reading. Inert unless armed.
        TitleBarResizeTrace.record(
            .geometry, detailFrame: frame, delta: shrink, undershoot: resizeUndershoot,
            rung: tracedRung)
        #endif
    }

    /// Gives the resize undershoot back once the window has stood still, so the row
    /// unfolds to its exact width.
    ///
    /// Debounced rather than driven by an end-of-resize event, because there is no
    /// such event to observe: a drag that stops simply produces no further geometry
    /// callback, and taking the window's `NSWindowDelegate` to hear about it is off
    /// the table (see `WindowFloor`). So the end of a resize is inferred from the
    /// absence of a pass, which is what restarting the wait on a measurement outside a
    /// live resize expresses.
    ///
    /// Absence of a pass is necessary but not sufficient, which is why the wait
    /// repeats: a hand-driven drag is bursts of passes separated by pauses longer than
    /// the settle delay, so a release that fired into one of those pauses would hand
    /// the width back and the next burst would take it straight off again — the row
    /// springing open and shut once per burst. Waiting again while the window is still
    /// in its live resize gives the undershoot back exactly once, after the drag has
    /// actually ended.
    private func scheduleUndershootRelease() {
        guard resizeUndershoot > 0 else {
            undershootReleaseTask?.cancel()
            undershootReleaseTask = nil
            return
        }
        // Restarting the wait is only load-bearing OUTSIDE a live resize, where the one
        // sleep below IS the debounce. Inside one, the `while` already keeps the task
        // alive to the true end of the drag, so cancelling and recreating it would cost
        // a `Task` per layout pass — 60–120 a second — on the hot path of the very drag
        // this smoothing exists for. Skipping that is semantically free: the undershoot
        // only ever grows while live (see `nextUndershoot`), so a later pass cannot
        // change what the running task has left to do, which is to release once.
        if Self.isWindowInLiveResize, undershootReleaseTask != nil { return }
        undershootReleaseTask?.cancel()
        undershootReleaseTask = Task { @MainActor in
            repeat {
                try? await Task.sleep(for: Self.undershootSettleDelay)
                guard !Task.isCancelled else { return }
            } while Self.isWindowInLiveResize
            resizeUndershoot = 0
            // Cleared so the NEXT drag's first pass starts a fresh wait rather than
            // finding this finished one and skipping it.
            undershootReleaseTask = nil
            #if DEBUG
            // The declared width changing without a layout pass behind it — the other
            // half of what the trace has to show. No pass measured a shrink here, so
            // the sample carries no delta.
            TitleBarResizeTrace.record(
                .release, detailFrame: detailFrame, delta: nil, undershoot: 0, rung: tracedRung)
            #endif
        }
    }

    #if DEBUG
    /// The hook the row reports its ladder rung through, or `nil` when no trace was
    /// armed — and a `nil` hook is what keeps the reporter out of the row's view tree
    /// entirely, so an unarmed session pays nothing.
    ///
    /// A report arrives whenever the rung's geometry changes and on the first layout of
    /// a newly selected candidate (see `TitleBarRungReporter`), so during a drag it
    /// arrives every pass — hence the filter: only a CHANGE of rung is worth a state
    /// write and a line of its own, since a pass that moved the geometry has already
    /// logged one.
    private var traceRungHook: ((TitleBarRung) -> Void)? {
        guard TitleBarResizeTrace.isEnabled else { return nil }
        return { rung in
            guard rung != tracedRung else { return }
            tracedRung = rung
            TitleBarResizeTrace.record(
                .rung, detailFrame: detailFrame, delta: nil, undershoot: resizeUndershoot,
                rung: rung)
        }
    }
    #endif

    /// The width the title bar has for this row, carrying whatever extra undershoot
    /// the resize in progress calls for.
    ///
    /// The detail area is ordinary in-window content, so it measures reliably —
    /// unlike anything read back from the toolbar itself. Everything else about the
    /// row's layout is then decided by the `HStack` from this one number.
    private var rowWidth: CGFloat {
        Self.rowWidth(detailFrame: detailFrame, undershoot: resizeUndershoot, isFullScreen: isFullScreen)
    }

    /// Whether the workspace window is in the middle of a pointer-driven resize.
    ///
    /// Read off the WINDOW rather than off a view: `NSView.inLiveResize` is true only
    /// for the views AppKit happens to resize inside its drag-tracking loop, which is
    /// an optimisation detail, whereas "this pass belongs to a user drag" is a
    /// property of the window. No `NSWindowDelegate` is taken for it (see
    /// `WindowFloor`) — a re-arming debounce needs no observer, just this flag.
    private static var isWindowInLiveResize: Bool {
        workspaceWindow()?.inLiveResize == true
    }

    /// The first visible toolbar-bearing window, which is the only one Casper has: there
    /// is no New Window command (`CasperCommands` replaces `.newItem` with Space) and both
    /// auxiliary `NSWindow`s are borderless and never ordered on-screen — the same
    /// argument `performTitleBarDoubleClickAction` is written out against. `NSApp.windows`
    /// is documented unordered, so "first" is how the one match is found, not a ranking
    /// between candidates.
    ///
    /// Shared with the debug measurement harness, so the trace's `live=` field reports
    /// the very flag the row acts on.
    static func workspaceWindow() -> NSWindow? {
        NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
    }

    /// Whether a window notification's sender carries a toolbar, which — by the same
    /// argument as `workspaceWindow()` — makes it the workspace window. Checked on the
    /// sender itself rather than by identity, so it does not depend on the window's
    /// visibility mid-transition.
    private static func isToolbarWindow(_ sender: Any?) -> Bool {
        (sender as? NSWindow)?.toolbar != nil
    }

    /// Returns the width the detail area lost between the previous measurement and
    /// this one, which is the extra undershoot the row owes for this pass.
    ///
    /// Zero on a grow, zero when nothing moved, and zero for the very first
    /// measurement — all three are the cases where the row's one-pass lag leaves it
    /// narrower than the bar rather than wider, and so costs nothing.
    static func shrink(previousWidth: CGFloat?, newWidth: CGFloat) -> CGFloat {
        guard let previousWidth else { return 0 }
        return max(0, previousWidth - newWidth)
    }

    /// The undershoot to carry into this layout pass, from the one in force, the
    /// shrink the pass measured, and whether the window is being dragged right now.
    ///
    /// Pure, so the whole decision is pinned by `WorkspaceTitleBarWidthTests`. What is
    /// left untested is only what surrounds it in the view: the `@State` it is
    /// threaded through, the live-resize read, and the re-arming release debounce —
    /// none of which can be driven without a real window in a real drag.
    ///
    /// Two rules, and the second is the load-bearing one:
    ///
    /// - **Capped** at `maximumResizeUndershoot`, because a coalesced pass reports the
    ///   whole distance travelled since the last one and subtracting that whole would
    ///   collapse the row (see that constant).
    /// - **Ratcheted** while the drag is live: within one drag the undershoot may only
    ///   grow. The declared width has to be MONOTONE while the window is dragged
    ///   narrower, because the row's `ViewThatFits` ladder is chosen from it (see
    ///   `WorkspaceTitleBarRow`) — a width that falls and rises again brings the diff
    ///   badge, the Space name and the chip labels back mid-drag, and non-monotone
    ///   degradation is the exact failure the single ordered ladder exists to prevent.
    ///   A real drag's per-pass deltas fluctuate freely, so without this the width
    ///   fluctuates with them.
    ///
    /// Outside a live resize there is no drag to be monotone across — a zoom or a
    /// programmatic `setFrame` is one isolated jump — so the capped shrink applies
    /// as-is and is anticipated once rather than held.
    static func nextUndershoot(current: CGFloat, shrink: CGFloat, isLiveResize: Bool) -> CGFloat {
        let capped = min(shrink, maximumResizeUndershoot)
        return isLiveResize ? max(current, capped) : capped
    }

    /// The width the row declares for a measured detail frame, given the shrink that
    /// frame represents.
    ///
    /// Pure, and kept that way: this is the decision the flicker turns on, and it is
    /// pinned by `WorkspaceTitleBarWidthTests` without a window in sight. The view
    /// owns only the `@State` behind the two arguments.
    ///
    /// `undershoot` makes the declared width fall at least as fast as the bar for as
    /// long as the bar falls by no more than `maximumResizeUndershoot` per pass: within
    /// that bound the value AppKit judges — which is always the PREVIOUS pass's, see
    /// `healToolbarOverflow` — is already narrow enough for the bar of the pass
    /// that follows. Past the cap it is not, and the frame of chevron that follows is
    /// what `healToolbarOverflow` takes back.
    ///
    /// `isFullScreen` only matters with the sidebar collapsed: it picks which chrome
    /// reserve the row pays (see `fullScreenChromeReserve`).
    static func rowWidth(detailFrame: CGRect?, undershoot: CGFloat, isFullScreen: Bool) -> CGFloat {
        guard let detailFrame else { return unmeasuredRowWidth }
        let chromeReserve = isFullScreen ? fullScreenChromeReserve : windowChromeReserve
        let windowChrome = detailFrame.minX < 1 ? chromeReserve : 0
        // Never negative: at a window narrower than the sidebar the detail area is a
        // few points wide, and a row wider than that would overflow.
        let settled = max(0, detailFrame.width - windowChrome - safetyMargin)
        // The undershoot must not carry the row across the mount threshold. Below it
        // the item is dropped from the toolbar entirely (see the `.toolbar` builder),
        // and an item that unmounts and remounts once per frame of a drag is a worse
        // flicker than the overflow the undershoot exists to prevent. A row that does
        // not fit even settled is left to unmount as it would have.
        guard settled >= minimumRowWidth else { return settled }
        return max(minimumRowWidth, settled - undershoot)
    }
}

extension NSWindow {
    /// Whether the toolbar is currently showing its clipped-items chevron.
    ///
    /// Shared by the toolbar overflow heal (`healToolbarOverflow`) and by the title
    /// bar's measurement harness (`WorkspaceDetailView+ToolbarProbe.swift`), which
    /// reports it as the one reliable signal that the row has been pushed into the
    /// overflow popover.
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
/// It is one view because it is one `ToolbarItem` (see the toolbar's own comment).
/// As that width shrinks, the row degrades along ONE ordered ladder — the diff badge
/// first, then the Space name, then the chip labels, and never the branch — spelled
/// out in `body` and in app-ui.md § Title bar.
struct WorkspaceTitleBarRow: View {
    let model: AppModel
    let workspace: Workspace
    /// The diff badge's counts, from `DiffService.diffSummary`; nil hides the badge.
    let diff: (insertions: Int, deletions: Int)?
    let width: CGFloat

    /// Report what the badge and the chips laid out to, so the row's layout tests can
    /// see which rung it settled on. A fixed-width stack tells an outside observer
    /// nothing about what is inside it, and the ladder's order — and its
    /// monotonicity — is precisely what needs pinning. Unused by the app.
    var onBadgeWidth: ((CGFloat) -> Void)?
    var onChipsWidth: ((CGFloat) -> Void)?

    #if DEBUG
    /// Report which rung of the ladder below actually laid out — the one thing the two
    /// widths above cannot say, since a density's width depends on which chips the
    /// workspace even offers and the title's form is not a function of width at all.
    /// Set only while a resize trace is armed (see `TitleBarResizeTrace`), and nil
    /// otherwise, which is what keeps the reporter — and the `TitleBarRung` it would
    /// name — out of the view tree.
    var onRung: ((TitleBarRung) -> Void)?
    #endif

    var body: some View {
        // Resolved once per body pass rather than per title: `model.space(for:)` scans
        // every Space's workspaces, and `ViewThatFits` builds all six rungs below.
        let space = model.space(for: workspace)
        // ONE ordered list for everything that yields, widest first, each rung giving
        // up exactly one thing: the badge (informational), then the Space name
        // (context), then the chip labels (actions). The branch (identity) never goes.
        // One list rather than one ladder per element, because two ladders cannot be
        // ordered against each other: whatever one releases, the other takes back
        // (measured, and tabulated rung by rung, in app-ui.md § Title bar). Within a
        // rung the branch still middle-truncates — `Text` answering a proposal, which
        // changes how a rung looks, never which rung is chosen.
        ViewThatFits(in: .horizontal) {
            rung(title: .spaceAndBranch, badge: true, chips: .full, space: space)
            rung(title: .spaceAndBranch, badge: false, chips: .full, space: space)
            rung(title: .branchOnly, badge: false, chips: .full, space: space)
            rung(title: .branchOnly, badge: false, chips: .mergeGlyph, space: space)
            rung(title: .branchOnly, badge: false, chips: .folded, space: space)
            rung(title: .branchOnly, badge: false, chips: .minimal, space: space)
        }
        // Giving the row a definite width is what drives the ladder: it hands it a real
        // proposal, which a toolbar item on its own never does.
        .frame(width: width, alignment: .leading)
        // Spanning the bar takes `NSThemeFrame`'s window drag and title-bar double-click
        // away, so a clear layer BEHIND the row carries both: a sibling of the chips,
        // never a gesture on their ancestor, which would delay every chip's press. See
        // the `titlebar-row-window-drag` note for the layer's shape and placement.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { performTitleBarDoubleClickAction() }
                .gesture(WindowDragGesture())
        }
    }

    /// Run the title bar's configured double-click action on the key window.
    ///
    /// The key window is this row's window: Casper has no New Window command
    /// (`CasperCommands` replaces `.newItem` with Space), and both auxiliary
    /// `NSWindow`s are borderless and never ordered on-screen. A sheet is the one
    /// other thing that takes key, which the guard below turns away.
    private func performTitleBarDoubleClickAction() {
        guard let window = NSApp.keyWindow else { return }
        // `performZoom` and `performMiniaturize` BEEP at a window that cannot honour
        // them, where the theme frame is silent. Two windows here cannot: one showing
        // or belonging to a sheet (the close-progress sheet in `RootView` makes the
        // sheet key), and a full-screen one.
        guard window.sheetParent == nil, window.attachedSheet == nil,
            !window.styleMask.contains(.fullScreen)
        else { return }

        let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        switch TitleBarDoubleClickAction.action(for: setting) {
        case .zoom:
            window.performZoom(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .fill:
            // Fill has no `NSWindow` verb of its own: it is the window taking the
            // screen's whole visible frame, which zoom does not guarantee.
            if let screen = window.screen {
                window.setFrame(screen.visibleFrame, display: true)
            }
        case .none:
            break
        }
    }

    /// One rung, laid out left to right: title, badge, then the chips at the trailing
    /// edge. `space` is the workspace's owning Space, which names the title.
    private func rung(
        title titleForm: WorkspaceTitleLabel.Form, badge: Bool,
        chips: WorkspaceToolbarActions.Density, space: Space?
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                title(titleForm, space: space)
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
        #if DEBUG
        // Reported from INSIDE the rung, because that is what makes the report
        // trustworthy: `ViewThatFits` places only the candidate it chose, so only the
        // chosen rung's background is ever laid out. A background is proposed the
        // primary view's size and answers with it, so this cannot change the width
        // `ViewThatFits` measured — the row has to observe itself without disturbing
        // what it observes.
        //
        // The `if` is OUTSIDE the reporter, not a check inside it: a `background`
        // closure is evaluated while the body is being built, so a reporter built
        // unconditionally would construct one `TitleBarRung` per candidate — six per
        // body pass — in every DEBUG session, armed or not. This way an unarmed session
        // builds nothing here at all.
        .background {
            if let onRung {
                TitleBarRungReporter(
                    rung: TitleBarRung(title: titleForm, badge: badge, chips: chips),
                    report: onRung)
            }
        }
        #endif
    }

    private func title(_ form: WorkspaceTitleLabel.Form, space: Space?) -> some View {
        WorkspaceTitleLabel(
            isGitRepo: space?.isGitRepo ?? false,
            spaceName: space?.name ?? workspace.name,
            branchLabel: workspace.branchLabel,
            form: form)
        // Chrome-less on purpose: the title is not a control, so it keeps the
        // shared capsule metrics (alignment with the chips) without the pill.
        // Asymmetric interior padding (not the shared `titleCapsule`'s symmetric
        // inset): the leading edge still owes its distance to the window edge,
        // while the trailing edge is tuned so the title-to-glyph gap (this
        // inset + the info button's own 2 pt inner padding) matches the
        // glyph-to-badge gap on the other side of the info chip.
        .padding(.leading, TitleCapsuleMetrics.horizontalInset)
        .padding(.trailing, 6)
        .frame(height: TitleCapsuleMetrics.height)
        // Out of hit testing, so a click on the title falls through to the drag and
        // double-click layer behind the row (see `body`). Its text takes the clicks
        // that land on it, and the layer is the title's sibling, not its ancestor, so
        // a click the title takes never reaches it. Opting out is simpler
        // than repeating the gestures here: the title is not a control and answers no
        // pointer of its own, and one gesture site is one that cannot drift.
        .allowsHitTesting(false)
    }

    @ViewBuilder private var diffBadge: some View {
        // Any summary shows, `+0 −0` included; `DiffService.diffSummary` is what
        // leaves a worktree with nothing to show at nil.
        if let summary = diff {
            Button {
                model.toggleInspectorTab(.diff, for: workspace.id)
            } label: {
                diffCounters(summary)
                    .titleCapsule()
            }
            .buttonStyle(TitleChipButtonStyle())
            .help("Toggle diff")
        }
    }

    /// The badge's two counters.
    private func diffCounters(_ summary: (insertions: Int, deletions: Int)) -> some View {
        HStack(spacing: 5) {
            Text("+\(summary.insertions)").foregroundStyle(Color(nsColor: DiffLineStyle.insertionTint).opacity(0.9))
            Text("−\(summary.deletions)").foregroundStyle(Color(nsColor: DiffLineStyle.deletionTint).opacity(0.9))
        }
        .font(.body.monospacedDigit().bold())
    }
}


/// What double-clicking the title bar does, as System Settings > Desktop & Dock >
/// "Double-click a window's title bar to" offers it: Fill, Zoom, Minimize or Do
/// Nothing. The choice is stored under `AppleActionOnDoubleClick`, where Zoom is
/// written as `Maximize` and an untouched setting writes no key at all.
///
/// Split out from `WorkspaceTitleBarRow` so the mapping can be tested. Reading the
/// domain and calling the `NSWindow` verbs both need a real window and a real user,
/// so they stay at the call site where nothing could test them anyway; what is worth
/// pinning is this decision, which has an unset default and an unknown-value case to
/// get wrong, and both must land on zoom.
enum TitleBarDoubleClickAction {
    case zoom
    case minimize
    case fill
    case none

    /// The stored value read as an action. Anything unrecognised — a value from a
    /// later macOS, or no value at all — is zoom, which is what macOS itself does.
    static func action(for value: String?) -> Self {
        switch value {
        case "Minimize": .minimize
        case "Fill": .fill
        case "None": .none
        default: .zoom
        }
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

    /// `Workspace.canMerge` for the workspace this row renders. Mirrors the menus'
    /// `canCloseSelectedWorkspace` gate, but derives from that workspace instead of
    /// the model's selection — the toolbar always acts on the workspace it is drawn
    /// for, which this view already holds.
    private var canMerge: Bool { workspace.canMerge }

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
            Label { Text(kind.displayName) } icon: { AppIcon(image: icon) }
        } else {
            Text(kind.displayName)
        }
    }

    /// The `⋯` chip: every action the row can no longer show, behind one menu. At
    /// `.minimal` it also carries the Diff / Browser toggles, which have no
    /// segmented control left to live in.
    ///
    /// `.menuStyle(.button)` + `TitleChipButtonStyle` rather than the split
    /// buttons' `.borderlessButton`, so the capsule can live INSIDE the label and
    /// the whole pill stays clickable (see the `title-capsule-hit-area` note). A
    /// borderless menu ignores its label's height and keeps its click target on
    /// the bare glyph, which measured 20×14 against this chip's 38×36. The button
    /// menu style draws its label through the button style in the environment, so
    /// this chip also gets the same pressed look as its neighbours. The chrome
    /// stays the explicit fill + hairline border — never glass, which renders
    /// nearly invisible around a nested `Menu`
    /// (`glasseffect-nested-menu-invisible`).
    private func foldedChip(_ density: Density) -> some View {
        Menu {
            foldedMenuContent(density)
        } label: {
            Image(systemName: "ellipsis")
                .glyphSlot()
                .titleCapsule()
        }
        .menuStyle(.button)
        .buttonStyle(TitleChipButtonStyle())
        // The chip button style draws no disclosure chevron of its own; this
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
                    .disabled(model.isSetupRunning(in: workspace.id))
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
    /// The width this control always lays out to — two identical segments, and the
    /// capsule shell adds nothing around them.
    ///
    /// Each segment is one glyph chip wide, from the shared metrics: the sliding
    /// indicator would otherwise change size as it moved between two symbols of
    /// different widths, and the segments would not match the chips beside them.
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
        .titleCapsuleShell()
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
        .buttonStyle(TitleChipButtonStyle())
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
    /// Disables the primary action only; the menu stays open to choose from.
    var isActionEnabled = true
    let action: () -> Void
    @ViewBuilder let primaryLabel: () -> PrimaryLabel
    @ViewBuilder let menuContent: () -> MenuContent

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                primaryLabel()
                    .padding(.leading, TitleCapsuleMetrics.horizontalInset)
                    .padding(.trailing, 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TitleChipButtonStyle())
            .disabled(!isActionEnabled)

            Menu(content: menuContent) {
                // .menuStyle(.borderlessButton) always appends its own disclosure chevron
                // after the label, so a label chevron here would render twice (⌄⌄). Keep
                // the label empty and let the style's own arrow be the only visible one.
                Color.clear.frame(width: 4, height: 20)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Fill the capsule's right inset so its trailing edge isn't a dead zone.
            .padding(.trailing, TitleCapsuleMetrics.horizontalInset)
        }
        .titleCapsuleShell()
    }
}

/// The "Run Script" toolbar split-button. It holds no state of its own; it stays a
/// separate view to keep the toolbar item's body readable.
private struct ScriptToolbarButton: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        let commands = model.namedCommands(for: workspace.id)
        let current = model.resolvedScript(for: workspace)
        // Running waits for the workspace's setup hook; choosing the script does not, so
        // only the primary action is disabled meanwhile.
        return TitleSplitButton(isActionEnabled: !model.isSetupRunning(in: workspace.id)) {
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
            .titleCapsule()
        }
        .buttonStyle(TitleChipButtonStyle())
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
    /// to their content come out uneven — measured, the five symbols that sit in it
    /// are `arrow.triangle.merge` and `plusminus` at 12 pt, `ellipsis` at 14, and
    /// `trash` and `globe` at 15. A row of glyph-only chips is a row of identical
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

/// How a title-bar chip answers the pointer: the capsule's fill at rest, under the
/// pointer and held down, and what a held chip does on top of that.
///
/// The fills are one neutral step each, the same in both palettes (no accent, see
/// the `title-bar-chip-chrome` note), and each state reads stronger than the one
/// before it — pressed has to read past hover, because the pointer is always over
/// a chip while it is held, so a press that only matched hover would show nothing.
/// Named rather than spelled at the call site so `TitleChipFeedbackTests` can pin
/// that ordering against the very numbers the chrome applies.
enum TitleChipFeedback {
    static let restingFillOpacity = 0.15
    static let hoveredFillOpacity = 0.28
    static let pressedFillOpacity = 0.40

    /// How far a held chip shrinks around its centre. A render-only effect, so the
    /// row never reflows under a click; kept slight because the whole pill — text,
    /// glyph and capsule together — moves, which reads as a press long before it
    /// reads as a resize.
    static let pressedScale: CGFloat = 0.95

    /// The info button's bare glyph has no capsule to darken, so its press is
    /// carried by the glyph alone. It shrinks further than a chip because it is far
    /// smaller: 5% of a 15 pt glyph is under a point and would not register.
    static let pressedGlyphScale: CGFloat = 0.85
    static let pressedGlyphOpacity = 0.6

    /// What `.plain` does to a disabled label, measured — so swapping it for
    /// `TitleChipButtonStyle` leaves a disabled Run action looking exactly as it did.
    static let disabledOpacity = 0.5

    /// The same short ease-out as the hover highlight, in both directions: a click
    /// lasts about a tenth of a second, so the press has to land and release within
    /// that window to be seen at all.
    static var animation: Animation { .easeOut(duration: 0.12) }

    /// The capsule's fill opacity. Pressed wins over hovered, which wins over
    /// resting.
    static func fillOpacity(hovered: Bool, pressed: Bool) -> Double {
        if pressed {
            return pressedFillOpacity
        }
        if hovered {
            return hoveredFillOpacity
        }
        return restingFillOpacity
    }
}

/// The button style every title-bar chip uses in place of `.plain`: the label
/// drawn untouched, with its press reported to the capsule chrome.
///
/// `.plain` exposes no press to the chrome, so under it a held chip looks exactly
/// like a hovered one. The chrome is what answers the press, but it sits on either
/// side of the button depending on the chip — INSIDE the label for single-button
/// chips (the diff badge, Merge, `⋯`), AROUND the button for the shells (Run /
/// Editor, the inspector selector), see the `title-capsule-hit-area` note — so the
/// style publishes the press both ways: down through `\.titleChipPressed` and up
/// through `TitleChipPressedKey`. The info button, which has no chrome, reads the
/// environment side directly through `titleChipGlyphPressEffect()`.
///
/// Otherwise it behaves like `.plain`: no padding, no background, and a hit area
/// that is exactly the label's shape, which every chip's geometry relies on.
struct TitleChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TitleChipButtonBody(configuration: configuration)
    }
}

/// `TitleChipButtonStyle`'s body, as a view of its own so it can read `isEnabled`
/// for the disabled look.
private struct TitleChipButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .environment(\.titleChipPressed, configuration.isPressed)
            .preference(key: TitleChipPressedKey.self, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : TitleChipFeedback.disabledOpacity)
    }
}

extension EnvironmentValues {
    /// Whether the `TitleChipButtonStyle` button this view sits inside is held
    /// down. Read by chrome drawn inside a button's label, and by the info button's
    /// glyph.
    @Entry var titleChipPressed = false
}

/// Carries `isPressed` up from a `TitleChipButtonStyle` button to the capsule shell
/// wrapping it. OR-reduced, so a shell holding two buttons — the inspector
/// selector's segments — reads as pressed while either one is.
private struct TitleChipPressedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The capsule chrome itself — fixed height, fill, hairline border, hit shape —
/// plus the hover highlight that makes a chip read as clickable, and the pressed
/// look that confirms the click: the fill steps past hover and the
/// whole pill shrinks slightly (fill alone under Reduce Motion).
///
/// It lives in a `ViewModifier` (rather than as `.onHover` on each call site) for
/// the `@State` it needs, and because sitting on the shell makes hover cover the
/// WHOLE pill, including the nested borderless `Menu` chevron of the split
/// buttons — a per-control `.onHover` would flicker as the pointer crosses them.
private struct TitleCapsuleChrome: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The press of the button whose label this chrome is drawn in.
    @Environment(\.titleChipPressed) private var enclosingButtonPressed
    @State private var hovering = false
    /// The press of a button this chrome wraps, reported up from inside it.
    @State private var wrappedButtonPressed = false

    private var pressed: Bool { enclosingButtonPressed || wrappedButtonPressed }

    /// Native toolbar controls dim when the window stops being key/main, so the
    /// chips dim with them. Fading the whole shell keeps the glyphs,
    /// the +N/−N tints and the capsule in step, and opacity alone can never shift
    /// the layout.
    private var shellOpacity: Double { controlActiveState == .inactive ? 0.5 : 1 }

    private var fill: Color {
        Color.secondary.opacity(TitleChipFeedback.fillOpacity(hovered: hovering, pressed: pressed))
    }

    private var scale: CGFloat {
        pressed && !reduceMotion ? TitleChipFeedback.pressedScale : 1
    }

    func body(content: Content) -> some View {
        content
            .frame(height: TitleCapsuleMetrics.height)
            // A scoped animation rather than `.animation(_:value:)`: only the
            // chrome's own fill, border and scale animate here, never the label
            // inside it. Releasing a press is also when the click's action lands,
            // and a value-keyed animation would hijack whatever that action
            // changes in the label — the inspector indicator's slide, for one.
            .animation(TitleChipFeedback.animation) { chrome in
                chrome
                    .background(fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .scaleEffect(scale)
            }
            // Past the scale, so the hit shape stays the full-size capsule: a chip
            // shrinking under a press held near its rim must not slip out from
            // under the pointer and cancel that press.
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onPreferenceChange(TitleChipPressedKey.self) { wrappedButtonPressed = $0 }
            .opacity(shellOpacity)
            .animation(TitleChipFeedback.animation, value: controlActiveState)
    }
}

private extension View {
    /// The one shared title-bar capsule chrome. Every title-bar chip uses this so
    /// they render strictly identically. Explicit fill + hairline border (not
    /// Liquid Glass) because glass renders nearly invisible on chips that embed a
    /// nested borderless `Menu` (Run / Editor), so this is the only treatment that
    /// works for every chip.
    ///
    /// Every chip is a button, so the chrome lights up on hover like a native
    /// toolbar button and darkens while pressed; see `TitleCapsuleChrome`. The
    /// press needs the chip's button to use `TitleChipButtonStyle`.
    func titleCapsule() -> some View {
        self
            .padding(.horizontal, TitleCapsuleMetrics.horizontalInset)
            .titleCapsuleShell()
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
    /// decoration around the button (see the `title-capsule-hit-area` memory
    /// note). A wrapped button's press still reaches the shell, through
    /// `TitleChipButtonStyle`.
    func titleCapsuleShell() -> some View {
        modifier(TitleCapsuleChrome())
    }
}

extension View {
    /// The press feedback for a title-bar control with no capsule to darken — the
    /// info button's bare glyph: it shrinks and dims while the
    /// `TitleChipButtonStyle` button holding it is pressed (dims only under Reduce
    /// Motion).
    ///
    /// Apply it to the glyph itself, inside any frame or padding: the scale is a
    /// render-only effect, and on the glyph alone it leaves the button's bounds —
    /// and anything anchored to them, like the info button's popover — untouched.
    func titleChipGlyphPressEffect() -> some View {
        modifier(TitleChipGlyphPressEffect())
    }
}

private struct TitleChipGlyphPressEffect: ViewModifier {
    @Environment(\.titleChipPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        pressed && !reduceMotion ? TitleChipFeedback.pressedGlyphScale : 1
    }

    func body(content: Content) -> some View {
        // Scoped for the same reason as the capsule chrome's: the glyph's own
        // changes (its unread fill, its pulse) keep their own animations.
        content.animation(TitleChipFeedback.animation) { glyph in
            glyph
                .scaleEffect(scale)
                .opacity(pressed ? TitleChipFeedback.pressedGlyphOpacity : 1)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension ToolbarContent {
    /// Removes the shared glass background macOS 26 draws around a toolbar item, so
    /// only the chips' own capsules show.
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// An application icon that redraws when the appearance switches.
///
/// The light/dark variant of an app icon comes from the system icon style and is
/// resolved when the image is drawn. SwiftUI rasterizes `Image(nsImage:)` once and
/// never redraws it for a system switch, so the icon would keep its first variant.
/// Keying the view on `colorScheme` (which flips at the same moment, as Casper
/// follows the system appearance) forces a fresh render.
private struct AppIcon: View {
    let image: NSImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: image)
            .id(colorScheme)
    }
}

private extension View {
    /// An alert titled `title`, up while `message` holds a value: the message and an
    /// OK button, and dismissing it clears `message`.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            // Empty: dismissing the alert flips `isPresented` to false, and that
            // binding's setter is what clears the error.
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
