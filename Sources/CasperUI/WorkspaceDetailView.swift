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
    /// leaves about 16 pt of this as real slack (measured: app-ui.md § Design →
    /// "Title bar") — and `resizeUndershoot` covers a moving one, on top of this.
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
    /// § Design → "Title bar"). 40 pt is twice the fastest ordinary pass (measured:
    /// 5–20 pt) and just under one `⋯` chip plus its gap (38 + `chipGap` = 46). A
    /// larger jump is left to the single frame of chevron `healToolbarOverflow`
    /// recovers, not to a collapsed row.
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
            // `toolbar-overflows-before-squeezing` note and app-ui.md § Design → "Title bar").
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
    /// sidebar (see app-ui.md § Design → "Title bar").
    ///
    /// One invalidation is not always enough while AppKit is still settling, so this
    /// re-checks, and only while the clipped-items indicator is actually on screen.
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
