#if DEBUG
import AppKit
import CasperCore
import SwiftUI

/// A measurement harness for the title bar's degradation ladder and the window's
/// floor, driven from inside the running app.
///
/// ## What it measures
///
/// Two sweeps, one after the other:
///
/// - **`TIERPROBE SWEEP`** — resizes the window to each width in turn and, at each,
///   cycles the inspector through collapsed / diff / browser / collapsed, logging
///   what AppKit did with the toolbar: the row's width, which items are visible,
///   which overflowed, and whether the clipped-items chevron is on screen.
/// - **`TIERPROBE FLOOR`** — drives every sidebar x inspector combination down to
///   `NSWindow.contentMinSize` and reports the room the terminal region is left with,
///   which is what `WindowFloor` exists to protect.
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
/// `/usr/bin/log` by absolute path — `log` is a zsh builtin — and `grep -a`, because
/// the stream file is classified as binary. Use a dedicated `--session` so the sweep
/// never touches a real workspace layout (see the `app-sessions` memory note).
///
/// The window is resized from **inside** the app rather than by seeding a frame into
/// the defaults domain: a window frame written there is ignored at launch, so an
/// external sweep silently measures one window size over and over.
///
/// Nothing here runs unless `CASPER_TIERPROBE_WIDTHS` is set, and the whole file is
/// compiled out of a release build (see the `debug-channel-gating` memory note).
extension WorkspaceDetailView {
    /// Starts the sweep, if the environment asks for one. `sample` is read afresh at
    /// every log point, so the harness sees the view's live layout state without
    /// needing access to it.
    func startToolbarProbe(_ sample: @escaping () -> ToolbarProbeSample) {
        guard let list = ProcessInfo.processInfo.environment["CASPER_TIERPROBE_WIDTHS"] else {
            return
        }
        let widths = list.split(separator: ",").compactMap { Double($0) }
        Task { @MainActor in
            // Long enough for the first layout, the diff summary and the editor
            // detection to have settled, so the first width measures a steady row.
            try? await Task.sleep(for: .seconds(2.5))
            for width in widths {
                guard let window = Self.probeWindow() else { return }
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
    }

    /// Drives every sidebar x inspector combination down to the window's floor and
    /// reports the room the terminal region is left with.
    private func probeWindowFloor(_ sample: @escaping () -> ToolbarProbeSample) async {
        guard let window = Self.probeWindow() else { return }
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

    /// The window carrying the workspace UI.
    private static func probeWindow() -> NSWindow? {
        NSApp.windows.first { $0.toolbar != nil && $0.isVisible }
    }
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
#endif
