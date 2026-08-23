#if DEBUG
import AppKit
import CasperCore
import CasperGhostty

extension AppModel: DebugSurfaceProvider {
    /// Expose the selected workspace's live terminal to the debug harness. The
    /// `GhosttySurfaceView` for the current detail pane is located via the key
    /// window's content-view hierarchy (the SwiftUI representable hosts it).
    func debugSurfaces() -> [DebugSurfaceHandle] {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
              let view = Self.findSurfaceView(in: window.contentView),
              view.debugHasSurface,
              let id = selectedWorkspaceID,
              let workspace = workspace(id: id)
        else { return [] }
        let focused = (window.firstResponder === view)
        return [
            DebugSurfaceHandle(
                id: id.casperID,
                title: workspace.name,
                workingDirectory: workspace.worktreePath,
                focused: focused,
                readText: { [weak view] scrollback in view?.debugReadText(scrollback: scrollback) },
                sendText: { [weak view] text, submit in view?.debugSendText(text, submit: submit) },
                sendKeys: { [weak view] text in view?.debugSendKeys(text) },
                sendKey: { [weak view] text, mods in view?.debugSendKey(text, mods: mods) },
                sendAction: { [weak view] name in view?.debugSendAction(name) },
                mouseMove: { [weak view] x, y in view?.debugMouseMove(x: x, y: y) },
                geometry: { [weak view] in view?.debugGeometry() ?? .zero },
                focus: { [weak window, weak view] in window?.makeFirstResponder(view) },
                window: window,
                // Detection's conclusion, plus two of the three inputs it drew it from (the
                // third, the viewport text, is what `readText` above returns). Reported as
                // their own fields rather than by redefining `title`, which stays the workspace
                // name so nothing already reading it changes meaning.
                agentState: workspace.agentState.rawValue,
                oscTitle: { [weak view] in view?.readOSCTitle() },
                progressReport: { [weak view] in view?.readProgressReport()?.rawValue }),
        ]
    }

    private static func findSurfaceView(in view: NSView?) -> GhosttySurfaceView? {
        guard let view else { return nil }
        if let surface = view as? GhosttySurfaceView { return surface }
        for sub in view.subviews {
            if let found = findSurfaceView(in: sub) { return found }
        }
        return nil
    }
}

extension AppModel: DebugMemoryProvider {
    /// Sizes of the per-id caches and of the layout collections, so a churn test can
    /// attribute growth to a named collection instead of only to a rising footprint.
    /// Every one of these is keyed by a workspace or surface id, so each should fall
    /// back to its pre-churn value once the terminals are closed.
    ///
    /// `nsWindows` is not built here: `DebugServer` contributes it, being a property
    /// of the process rather than of the model.
    func debugMemoryCounters() -> [String: Int] {
        let workspaces = spaces.flatMap(\.workspaces)
        let sharedViews = GhosttyDebugCensus.sharedViewCounts
        return [
            "surfaceViews": debugSurfaceViewCount,
            "browserCoordinators": browserCoordinators.count,
            "pendingInitialInput": pendingInitialInput.count,
            "watcherPathsCache": watcherPathsCache.count,
            "namedCommandsCache": namedCommandsCache.count,
            "namedCommandsStamps": namedCommandsStamps.count,
            "agentResolvers": agentResolvers.count,
            "lastNotifiedAt": lastNotifiedAt.count,
            "spaces": spaces.count,
            "workspaces": workspaces.count,
            // The surfaces the layout trees still reference — the number
            // `surfaceViews` is expected to track.
            "layoutSurfaces": workspaces.reduce(0) { $0 + LayoutTree.surfaceIDs($1.layout).count },
            "sharedViewRegistryEntries": sharedViews.registryEntries,
            "sharedViewContainers": sharedViews.containers,
        ]
    }
}
#endif
