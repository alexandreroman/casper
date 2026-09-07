#if DEBUG
import AppKit
import CasperCore
import SwiftUI

/// A measurement harness for the title bar's degradation ladder and the window's
/// floor, driven from inside the running app.
///
/// ## What it measures
///
/// Three environment variables, of which only two drive a sweep:
/// `CASPER_TIERPROBE_WIDTHS` runs SWEEP and then FLOOR, `CASPER_RESIZESTEP` runs
/// RESIZESTEP, and when both are set they run in that order. `CASPER_RESIZETRACE`
/// drives nothing at all — it arms a passive TRACE and then waits for a human to
/// resize the window.
///
/// - **`TIERPROBE SWEEP`** — resizes the window to each width in turn and, at each,
///   cycles the inspector through collapsed / diff / browser / collapsed, logging
///   what AppKit did with the toolbar: the row's width, which items are visible,
///   which overflowed, and whether the clipped-items chevron is on screen.
/// - **`TIERPROBE FLOOR`** — drives every sidebar x inspector combination down to
///   `NSWindow.contentMinSize` and reports the room the terminal region is left with,
///   which is what `WindowFloor` exists to protect.
/// - **`TIERPROBE RESIZESTEP`** — walks the window's width down and back up in fixed
///   steps, sampling the title bar twice at every stop: once in the same runloop turn
///   as the `setFrame`, before SwiftUI has laid out again, and once after a settle
///   delay. The two sweeps above only ever measure a settled window, so they cannot
///   see the transient this one is aimed at.
/// - **`TIERPROBE TRACE`** — drives nothing and observes everything: one line per
///   layout pass that moves the detail area, plus one whenever the declared width or
///   the ladder rung changes for another reason. It is the only way to measure a
///   drag done with the pointer, and a drag done with the pointer is the only thing
///   that shows two facts the three sweeps above cannot produce: a real live resize,
///   and a per-pass delta that FLUCTUATES rather than stepping by a constant. Since
///   the declared width subtracts the delta the previous pass measured, a fluctuating
///   delta makes it fluctuate non-monotonically too — which can walk the row's ladder
///   back UP a rung mid-drag. See `TitleBarResizeTrace` for the fields and for how to
///   read a run of them.
///
/// Set both sweep variables and the resize walk **inherits the floor sweep's end
/// state** — the window sitting at `contentMinSize`, the sidebar and the inspector
/// wherever FLOOR left them — because it takes its origin and its height from the
/// window's current frame. The two sweeps are independent only when each is set on
/// its own.
///
/// ## Reading the result
///
/// **The chevron is the signal, and the item counts are not.** `toolbar.items.count`
/// never equals `toolbar.visibleItems?.count` here: SwiftUI's own
/// `com.apple.SwiftUI.splitViewSeparator-0` is absent from `visibleItems` at every
/// width, chevron or no chevron. The reliable test is whether an
/// `NSToolbarClippedItemsIndicator` exists in the window's view tree, which is what
/// the `chevron=` field reports. An overflowed row is not cosmetic — inside that
/// popover the chips render without their capsule chrome and the segmented control
/// clips to a lone glyph, which is the failure this whole ladder exists to prevent.
///
/// **`RESIZESTEP` logs a pair of lines per stop, and the pair is the point.** The row
/// is sized from `rowWidth`, which is derived from `detailFrame`, which only reaches
/// `@State` on SwiftUI's *next* layout pass — so the row is always one pass behind the
/// window. `when=immediate` is that stale instant: `window=` and `content=` have
/// already shrunk while `detail=`, `detailMinX=` and `row=` still hold the previous
/// pass's values. `when=settled` is the same requested width once the pass has run.
/// `chevron=` stays the authoritative field across the pair — a `phase=shrink
/// when=immediate` chevron that is gone by `when=settled` is the flicker, measured,
/// and `phase=grow` is the control, since a widening window leaves the stale row too
/// *narrow*, which nothing can see.
///
/// **`overhang=` is indicative magnitude, not a verdict.** It is `itemView=`'s
/// trailing edge minus the window's content width, and `itemView=` measures the
/// SwiftUI hosting view, which sits INSIDE the `NSToolbarItemViewer` AppKit actually
/// fits against the bar (measured: viewer `(232,0,492,52)`, hosting view
/// `(4,8,484,36)` — see the `titlebar-row-window-drag` memory note). So the number
/// understates the real overhang by that inset and can read negative on a line whose
/// `chevron=` is `YES`. That combination is exactly what a run with the undershoot in
/// place shows, so read the magnitude for how close a stop came and the chevron for
/// whether it went over.
///
/// ## Running it
///
/// ```sh
/// /usr/bin/log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' \
///   --level debug --style compact > /tmp/sweep.log &
/// CASPER_TIERPROBE_WIDTHS="1400,900,700,600,520,450" \
///   Casper-dev.app/Contents/MacOS/casper --session <name>
/// grep -a TIERPROBE /tmp/sweep.log
/// ```
///
/// The resize walk is driven the same way, with its own variable, formatted
/// `from,to,step,delayMs` — a start width, an end width below it, the decrement, and
/// the settle delay in milliseconds:
///
/// ```sh
/// /usr/bin/log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' \
///   --level debug --style compact > /tmp/resize.log &
/// CASPER_RESIZESTEP="1400,700,40,16" \
///   Casper-dev.app/Contents/MacOS/casper --session <name>
/// grep -a 'TIERPROBE RESIZESTEP' /tmp/resize.log
/// ```
///
/// The trace is armed the same way and then left alone — no widths, no steps, just
/// `1`, after which the window is resized BY HAND and the log read back:
///
/// ```sh
/// /usr/bin/log stream --predicate 'subsystem == "com.github.alexandreroman.casper"' \
///   --level debug --style compact > /tmp/trace.log &
/// CASPER_RESIZETRACE=1 Casper-dev.app/Contents/MacOS/casper --session <name>
/// # ... drag the window's right edge leftwards, slowly and then quickly ...
/// grep -a 'TIERPROBE TRACE' /tmp/trace.log
/// ```
///
/// `/usr/bin/log` by absolute path — `log` is a zsh builtin — and `grep -a`, because
/// the stream file is classified as binary. Use a dedicated `--session` so the sweep
/// never touches a real workspace layout (see the `app-sessions` memory note).
///
/// The window is resized from **inside** the app rather than by seeding a frame into
/// the defaults domain: a window frame written there is ignored at launch, so an
/// external sweep silently measures one window size over and over.
///
/// Nothing here runs unless `CASPER_TIERPROBE_WIDTHS` or `CASPER_RESIZESTEP` asks for
/// a sweep, or `CASPER_RESIZETRACE` arms the trace — any one on its own is enough. The
/// trace never interacts with the sweeps (it drives nothing), where the two sweeps do
/// interact when both are set, as above. The whole file is compiled out of a release
/// build (see the `debug-channel-gating` memory note).
extension WorkspaceDetailView {
    /// Starts the sweeps the environment asks for. `sample` is read afresh at every
    /// log point, so the harness sees the view's live layout state without needing
    /// access to it.
    func startToolbarProbe(_ sample: @escaping () -> ToolbarProbeSample) {
        let environment = ProcessInfo.processInfo.environment
        let widths = environment["CASPER_TIERPROBE_WIDTHS"].map { list in
            list.split(separator: ",").compactMap { Double($0) }
        }
        let resizePlan = environment["CASPER_RESIZESTEP"].flatMap(ResizeStepPlan.init(rawValue:))
        guard widths != nil || resizePlan != nil else { return }

        Task { @MainActor in
            // Long enough for the first layout, the diff summary and the editor
            // detection to have settled, so the first sample measures a steady row.
            try? await Task.sleep(for: .seconds(2.5))
            if let widths {
                await sweepTierWidths(widths, sample: sample)
            }
            if let resizePlan {
                await sweepResizeSteps(resizePlan, sample: sample)
            }
        }
    }

    /// Resizes the window to each width in turn, cycling the inspector at each one,
    /// then finishes at the window's floor.
    private func sweepTierWidths(_ widths: [Double], sample: @escaping () -> ToolbarProbeSample) async {
        for width in widths {
            guard let window = Self.workspaceWindow() else { return }
            window.setFrame(NSRect(x: 60, y: 200, width: width, height: 760), display: true)
            try? await Task.sleep(for: .milliseconds(1200))
            logToolbarState(window, requested: width, phase: "collapsed", sample: sample())

            model.toggleInspectorTab(.diff, for: workspace.id)
            try? await Task.sleep(for: .milliseconds(1200))
            logToolbarState(window, requested: width, phase: "diff", sample: sample())

            model.toggleInspectorTab(.browser, for: workspace.id)
            try? await Task.sleep(for: .milliseconds(1200))
            logToolbarState(window, requested: width, phase: "browser", sample: sample())

            model.toggleInspectorTab(.browser, for: workspace.id)
            try? await Task.sleep(for: .milliseconds(1200))
            logToolbarState(window, requested: width, phase: "recollapsed", sample: sample())
        }
        await probeWindowFloor(sample)
    }

    /// Drives every sidebar x inspector combination down to the window's floor and
    /// reports the room the terminal region is left with.
    private func probeWindowFloor(_ sample: @escaping () -> ToolbarProbeSample) async {
        guard let window = Self.workspaceWindow() else { return }
        for sidebarOpen in [true, false] {
            if !sidebarOpen {
                toggleSidebar()
                try? await Task.sleep(for: .milliseconds(900))
            }
            for tab in [nil, InspectorTab.diff, .browser] as [InspectorTab?] {
                await setInspector(tab)
                // `setFrame` bypasses `contentMinSize` — it constrains user drags, not
                // programmatic sizing — so drive the window TO the floor instead and
                // measure there, which is the state a drag comes to rest in. Twice,
                // because the first pass can move the floor it is aiming at.
                window.setContentSize(window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(1000))
                window.setContentSize(window.contentMinSize)
                try? await Task.sleep(for: .milliseconds(1000))

                let current = sample()
                let inspectorSlice = model.terminalHostMetrics?.inspectorSlice ?? 0
                let terminal = CGSize(
                    width: (current.detailFrame?.width ?? 0) - inspectorSlice,
                    height: (current.detailFrame?.height ?? 0)
                        - WorkspaceDetailView.paneDividerHeight)
                CasperLog.app.debug(
                    """
                    TIERPROBE FLOOR sidebar=\(sidebarOpen ? "open" : "collapsed", privacy: .public) \
                    tab=\(tab.map(String.init(describing:)) ?? "collapsed", privacy: .public) \
                    window=\(window.frame.width, privacy: .public)x\
                    \(window.frame.height, privacy: .public) \
                    contentMin=\(window.contentMinSize.width, privacy: .public)x\
                    \(window.contentMinSize.height, privacy: .public) \
                    minSize=\(window.minSize.width, privacy: .public)x\
                    \(window.minSize.height, privacy: .public) \
                    terminal=\(terminal.width, privacy: .public)x\
                    \(terminal.height, privacy: .public)
                    """)
            }
            if !sidebarOpen {
                toggleSidebar()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    /// Walks the window's width down and back up in fixed steps, sampling the title
    /// bar twice at every stop.
    private func sweepResizeSteps(
        _ plan: ResizeStepPlan, sample: @escaping () -> ToolbarProbeSample
    ) async {
        let shrinking = plan.shrinkWidths
        let phases: [(name: String, widths: [CGFloat])] = [
            ("shrink", shrinking),
            ("grow", shrinking.reversed()),
        ]
        for phase in phases {
            for width in phase.widths {
                guard let window = Self.workspaceWindow() else { return }
                // A window's origin is its BOTTOM-left, so holding the origin and the
                // height fixed is what pins the top-left corner — the same corner a
                // drag on the right edge leaves in place.
                let frame = window.frame
                window.setFrame(
                    NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
                    display: true)
                // Deliberately no await between the `setFrame` and this log: this is
                // the stale instant, where AppKit has already laid the toolbar out but
                // SwiftUI's next pass — and so `detailFrame` — has not run yet.
                logResizeStep(
                    window, phase: phase.name, when: "immediate", requested: width,
                    sample: sample())

                try? await Task.sleep(for: plan.settleDelay)
                logResizeStep(
                    window, phase: phase.name, when: "settled", requested: width,
                    sample: sample())
            }
        }
    }

    /// Drives the inspector to an explicit state through the same mutator the UI uses.
    /// `toggleInspectorTab` switches, expands or collapses depending on where it
    /// starts, so this steps until the state matches rather than assuming one hop.
    private func setInspector(_ tab: InspectorTab?) async {
        for _ in 0..<3 {
            guard let current = model.workspace(id: workspace.id) else { return }
            let showing: InspectorTab? = current.inspector.collapsed ? nil : current.inspector.tab
            if showing == tab { return }
            model.toggleInspectorTab(tab ?? current.inspector.tab, for: workspace.id)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// `RootView`'s `columnVisibility` is private `@State`, so the sidebar is driven
    /// the way the toolbar's own button drives it.
    private func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    private func logToolbarState(
        _ window: NSWindow, requested: Double, phase: String, sample: ToolbarProbeSample
    ) {
        guard let toolbar = window.toolbar else { return }
        let visible = Set(toolbar.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
        // SwiftUI names its own items; ours are the ones identified by a UUID.
        let ours = toolbar.items
            .filter { UUID(uuidString: $0.itemIdentifier.rawValue) != nil }
            .map { item in
                let width = item.view.map { "\($0.frame.width)" } ?? "-"
                return "\(visible.contains(item.itemIdentifier.rawValue) ? "V" : "OVF"):\(width)"
            }
        let overflowed = toolbar.items
            .filter { !visible.contains($0.itemIdentifier.rawValue) }
            .map(\.itemIdentifier.rawValue)
        let detail = sample.detailFrame?.debugDescription ?? "nil"
        CasperLog.app.debug(
            """
            TIERPROBE SWEEP want=\(requested, privacy: .public) phase=\(phase, privacy: .public) \
            got=\(window.frame.width, privacy: .public) \
            detail=\(detail, privacy: .public) row=\(sample.rowWidth, privacy: .public) \
            items=\(toolbar.items.count, privacy: .public) \
            visible=\(toolbar.visibleItems?.count ?? -1, privacy: .public) \
            ours=[\(ours.joined(separator: ","), privacy: .public)] \
            overflowed=[\(overflowed.joined(separator: ","), privacy: .public)] \
            chevron=\(window.hasClippedToolbarItems ? "YES" : "no", privacy: .public)
            """)
    }

    /// One line per sample: what the window is, what SwiftUI still thinks it is, and
    /// how far our toolbar item currently reaches past the visible bar.
    private func logResizeStep(
        _ window: NSWindow, phase: String, when: String, requested: CGFloat,
        sample: ToolbarProbeSample
    ) {
        let contentWidth = window.contentRect(forFrameRect: window.frame).width
        let itemFrame = Self.probeItemFrameInWindow(window)
        let itemView = itemFrame.map { "\(probePoints($0.minX))+\(probePoints($0.width))" } ?? "-"
        let overhang = itemFrame.map { probePoints($0.maxX - contentWidth) } ?? "-"
        let detail = sample.detailFrame
        CasperLog.app.debug(
            """
            TIERPROBE RESIZESTEP phase=\(phase, privacy: .public) when=\(when, privacy: .public) \
            want=\(probePoints(requested), privacy: .public) \
            window=\(probePoints(window.frame.width), privacy: .public) \
            content=\(probePoints(contentWidth), privacy: .public) \
            detail=\(detail.map { probePoints($0.width) } ?? "nil", privacy: .public) \
            detailMinX=\(detail.map { probePoints($0.minX) } ?? "nil", privacy: .public) \
            row=\(probePoints(sample.rowWidth), privacy: .public) \
            itemView=\(itemView, privacy: .public) \
            overhang=\(overhang, privacy: .public) \
            chevron=\(window.hasClippedToolbarItems ? "YES" : "no", privacy: .public)
            """)
    }

    /// Our own toolbar item's view, in the window's coordinate space, so its trailing
    /// edge can be compared against the window's content width. Ours is the item whose
    /// identifier parses as a UUID — the same test `logToolbarState` uses.
    private static func probeItemFrameInWindow(_ window: NSWindow) -> CGRect? {
        let ours = window.toolbar?.items.first { UUID(uuidString: $0.itemIdentifier.rawValue) != nil }
        guard let view = ours?.view else { return nil }
        return view.convert(view.bounds, to: nil)
    }

    /// A `CASPER_RESIZESTEP` walk, parsed from `from,to,step,delayMs`.
    private struct ResizeStepPlan {
        let from: CGFloat
        let to: CGFloat
        let step: CGFloat
        let settleDelay: Duration

        init?(rawValue: String) {
            let fields = rawValue
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard fields.count == 4 else { return nil }
            let (from, to, step, delayMilliseconds) = (fields[0], fields[1], fields[2], fields[3])
            guard from > to, step > 0, delayMilliseconds >= 0 else { return nil }
            self.from = from
            self.to = to
            self.step = step
            self.settleDelay = .milliseconds(delayMilliseconds)
        }

        /// The widths of the shrink phase, `from` down to `to`. `to` is always the last
        /// one, even when the step does not divide the span evenly.
        var shrinkWidths: [CGFloat] {
            var widths = Array(stride(from: from, through: to, by: -step))
            if widths.last != to {
                widths.append(to)
            }
            return widths
        }
    }
}

/// One decimal keeps a probe line readable without hiding the sub-point drift that
/// distinguishes a stale measurement from a settled one.
private func probePoints(_ value: CGFloat) -> String {
    String(format: "%.1f", value)
}

/// The view's live layout state, as the harness sees it.
///
/// Handed in as a closure rather than read off the view, so the harness needs no
/// access to `WorkspaceDetailView`'s private measurements and the production file
/// gives up none of its encapsulation to a debug tool.
struct ToolbarProbeSample {
    let detailFrame: CGRect?
    let rowWidth: CGFloat
}

// MARK: - The passive trace

/// A passive trace of the title bar's geometry through a real, human-driven resize,
/// armed by `CASPER_RESIZETRACE=1`.
///
/// It drives nothing — no `setFrame`, no inspector toggling, no window of its own. It
/// exists because the sweeps at the top of this file replay a resize at a CONSTANT
/// step, and two properties of a pointer drag are invisible to a replay:
///
/// - a real live resize: AppKit's drag-tracking run-loop mode, with the coalesced
///   layout passes that come with it;
/// - a per-pass delta that FLUCTUATES. The declared width subtracts the shrink the
///   previous pass measured (see
///   `WorkspaceDetailView.rowWidth(detailFrame:undershoot:)`), so a delta that
///   wobbles makes the declared width wobble non-monotonically — and a
///   non-monotonic width can walk the row's `ViewThatFits` ladder back UP a rung and
///   down again inside one drag, which is a visible flicker of the chips. A
///   constant step cannot produce that, so a stepped sweep hides it by construction.
///
/// ## The line
///
/// ```
/// TIERPROBE TRACE seq=41 t=612.3 why=geometry live=YES window=1003.0 detail=783.0
///   detailMinX=220.0 delta=17.0 undershoot=17.0 row=742.0
///   rung=3/branchOnly/noBadge/full chevron=no
/// ```
///
/// - **`seq=`, `t=`** — the sample counter and milliseconds since the first sample of
///   the session. Together they give the cadence: a drag at 60 Hz produces samples
///   ~16 ms apart, so a longer gap is a coalesced or dropped frame and a `seq` jump
///   never happens (nothing is ever skipped).
/// - **`why=`** — what produced this sample. `geometry` is a layout pass that moved
///   the detail area, and it is the only reason that carries a `delta=`. `release`
///   is the undershoot being given back once the window stood still. `rung` is the
///   ladder changing rung, which is the only sample that can appear without the
///   geometry having moved at all.
/// - **`window=`** — the window's content width. `detail=` and `detailMinX=` are the
///   detail area's measured frame, and `minX` is what says whether the window's own
///   chrome shares this row.
/// - **`delta=`** — the shrink this pass observed, i.e. what
///   `WorkspaceDetailView.shrink(previousWidth:newWidth:)` returned. `-` on a sample
///   no layout pass produced.
/// - **`undershoot=`** — the state actually in effect, and `row=` the width the row
///   declares for it. `row=` is recomputed here from the same pure function the view
///   uses, so it cannot drift from what the row really declared. It parts company with
///   `delta=` on the passes worth reading: the undershoot is capped and, inside a live
///   resize, ratcheted (see `WorkspaceDetailView.nextUndershoot(current:shrink:isLiveResize:)`),
///   so a coalesced pass shows a large `delta=` against a bounded `undershoot=`.
/// - **`live=`** — whether the window is in a live resize. Read off the WINDOW
///   (`NSWindow.inLiveResize`), not off the content view: `NSView.inLiveResize` is
///   true only for the views AppKit actually resizes inside its drag-tracking loop,
///   and which views those are is an AppKit optimisation detail, whereas the fact
///   this field is for — "this sample belongs to a user drag" — is a property of the
///   window.
/// - **`rung=`** — which rung of the ladder `ViewThatFits` actually selected,
///   reported by the rung that laid out (see `TitleBarRungReporter`), numbered
///   widest-first. On a `why=rung` sample this is the change itself; on any other
///   sample it is the rung last reported, which can be one pass behind, because
///   SwiftUI does not order a child's geometry callback against the parent's.
/// - **`chevron=`** — `NSWindow.hasClippedToolbarItems`, i.e. whether AppKit has just
///   emptied the title bar into its overflow popover.
///
/// ## How to read a run
///
/// **Consecutive samples with `live=YES` are one drag.** Everything worth reading is
/// read within one such run, and the two failures it can contain are different bugs
/// with different fixes:
///
/// - **`rung=` goes DOWN and then back UP inside the run** — the ladder oscillated:
///   the row declared a width that did not fall monotonically, so the chips folded
///   and unfolded while the pointer kept moving. That is a flicker of the CHIPS, and
///   the fix is in how the declared width is derived (the undershoot term), not in
///   the toolbar.
/// - **`chevron=YES` on any sample of the run** — the row was wider than the bar at
///   the instant AppKit ran its fit check, so the whole title bar went into the
///   overflow popover for that frame. That is a flicker of the WHOLE BAR, and the
///   fix is that the declared width must be *narrower*, or `healToolbarOverflow` must
///   reach the case.
///
/// The two are independent: a run can oscillate rungs without ever raising the
/// chevron (the row kept fitting, it just kept changing its mind), and a run can
/// raise the chevron with a perfectly monotone rung sequence. Do not treat one as
/// evidence about the other.
///
/// Nothing here grows without bound, so a trace can be left armed for a whole
/// interactive session: the state is one counter and one clock stamp, and every
/// sample is written straight to the log.
@MainActor
enum TitleBarResizeTrace {
    /// Whether `CASPER_RESIZETRACE=1` armed the trace. Read once, at first use: this
    /// is consulted from a layout callback, which is the hot path of a drag.
    static let isEnabled = ProcessInfo.processInfo.environment["CASPER_RESIZETRACE"] == "1"

    /// What produced a sample. See the `why=` field above.
    enum Reason: String {
        case geometry
        case release
        case rung
    }

    /// Sample counter, so a reader can tell a gap in the cadence from a gap in the
    /// samples.
    private static var sequence = 0

    /// When the first sample of the session was taken; every `t=` is relative to it.
    /// A `ContinuousClock` because the trace measures elapsed real time across a
    /// drag, which must not be perturbed by a clock adjustment.
    private static var origin: ContinuousClock.Instant?

    /// Emits one line, or nothing at all when the trace was never armed.
    ///
    /// `rung` is passed in rather than read back: the row reports it upwards through
    /// its own hook, and the view holds it in private state.
    static func record(
        _ reason: Reason, detailFrame: CGRect?, delta: CGFloat?, undershoot: CGFloat,
        rung: TitleBarRung?
    ) {
        guard isEnabled else { return }

        let now = ContinuousClock.now
        let firstSample = origin ?? now
        origin = firstSample
        sequence += 1

        let window = WorkspaceDetailView.workspaceWindow()
        let content = window.map { $0.contentRect(forFrameRect: $0.frame).width }
        let row = WorkspaceDetailView.rowWidth(detailFrame: detailFrame, undershoot: undershoot)
        CasperLog.app.debug(
            """
            TIERPROBE TRACE seq=\(sequence, privacy: .public) \
            t=\(probeMilliseconds(firstSample.duration(to: now)), privacy: .public) \
            why=\(reason.rawValue, privacy: .public) \
            live=\(window?.inLiveResize == true ? "YES" : "no", privacy: .public) \
            window=\(content.map(probePoints) ?? "-", privacy: .public) \
            detail=\(detailFrame.map { probePoints($0.width) } ?? "nil", privacy: .public) \
            detailMinX=\(detailFrame.map { probePoints($0.minX) } ?? "nil", privacy: .public) \
            delta=\(delta.map(probePoints) ?? "-", privacy: .public) \
            undershoot=\(probePoints(undershoot), privacy: .public) \
            row=\(probePoints(row), privacy: .public) \
            rung=\(rung?.label ?? "-", privacy: .public) \
            chevron=\(window?.hasClippedToolbarItems == true ? "YES" : "no", privacy: .public)
            """)
    }
}

/// Which rung of `WorkspaceTitleBarRow`'s ladder is on screen.
///
/// A width tells an observer nothing here: which chips a density draws depends on
/// what the workspace can do (Merge, a script, an editor), so the same width can
/// belong to two densities and the title's form is not a function of width at all.
/// The rung therefore names itself, from inside the rung that laid out.
///
/// What it stores is the rung's three inputs, so `==` tells two combinations apart even
/// when both are unmapped and share the number `0` — `traceRungHook` filters repeats on
/// that comparison.
struct TitleBarRung: Equatable {
    let title: WorkspaceTitleLabel.Form
    let badge: Bool
    let chips: WorkspaceToolbarActions.Density

    /// Position on the ladder, widest first, 1-based — or `0` for a combination the
    /// row never builds. The number is what makes an oscillation legible: a rung
    /// that goes down and back up is the failure the trace is looking for.
    var number: Int {
        // Mirrors the `ViewThatFits` list in `WorkspaceTitleBarRow.body`, widest
        // first, and is the only place a rung NUMBER comes from — the body itself has
        // to spell its candidates out, since `ViewThatFits` takes each direct child as
        // one candidate and cannot be fed a list. `WorkspaceTitleBarRungTests` sweeps
        // the row's real selection against this mapping, so a rung added to one and
        // not the other fails the suite instead of quietly logging `0`.
        switch (title, badge, chips) {
        case (.spaceAndBranch, true, .full): 1
        case (.spaceAndBranch, false, .full): 2
        case (.branchOnly, false, .full): 3
        case (.branchOnly, false, .mergeGlyph): 4
        case (.branchOnly, false, .folded): 5
        case (.branchOnly, false, .minimal): 6
        default: 0
        }
    }

    /// The rung as the trace prints it, number first: `3/branchOnly/noBadge/full`.
    ///
    /// Composed on demand rather than in an initializer: interpolating the two enums
    /// goes through the reflective `String(describing:)` path, and an armed row builds
    /// one rung per candidate on every layout pass while the trace prints at most one
    /// of them.
    var label: String { "\(number)/\(title)/\(badge ? "badge" : "noBadge")/\(chips)" }
}

/// Reports the ladder rung that actually laid out, from inside that rung.
///
/// `ViewThatFits` places only the candidate it selected, so a reporter sitting in a
/// rung's own `background` speaks for the rung on screen and for no other.
///
/// What it delivers, on `.onGeometryChange` rather than `.onAppear`: a report whenever
/// the rung's geometry changes, and one on the first layout of a newly selected
/// candidate. A drag moves the row's width every pass, so it reports every pass there;
/// a rung change driven by content at a standing window (a diff summary arriving, a
/// script appearing) moves no geometry at all, and the report then comes from
/// `ViewThatFits` placing a different child — which is measured to happen, see
/// `WorkspaceTitleBarRungTests`.
///
/// It cannot move what it measures: a `background` is proposed the primary view's size
/// and answers with it, so it takes no part in sizing the rung — and an unarmed row
/// never builds it, the `if` living at the call site rather than in this body.
struct TitleBarRungReporter: View {
    let rung: TitleBarRung
    let report: (TitleBarRung) -> Void

    var body: some View {
        // Never drawn, never hit-tested: the row's own `contentShape` carries the
        // window drag, and a hit-testable background inside a rung would be one
        // more thing between the pointer and the title bar.
        Color.clear
            .allowsHitTesting(false)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in report(rung) }
    }
}

extension WorkspaceTitleBarRow {
    /// A copy of the row that reports the ladder rung it places to `report`.
    ///
    /// A method rather than one more argument at the call site, so the row's
    /// construction in `WorkspaceDetailView`'s toolbar stays a single expression and
    /// the trace hangs off one conditional line there. A `nil` `report` is the unarmed
    /// case and costs the row nothing: each rung's `background` builds neither the
    /// reporter nor the `TitleBarRung` it would carry.
    func reportingRung(_ report: ((TitleBarRung) -> Void)?) -> Self {
        var copy = self
        copy.onRung = report
        return copy
    }
}

/// A `Duration` in milliseconds, one decimal — enough to read a 60 Hz drag's cadence.
private func probeMilliseconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    return String(format: "%.1f", milliseconds)
}
#endif
