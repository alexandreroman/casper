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
              let workspace = workspaces.first(where: { $0.id == id })
        else { return [] }
        let focused = (window.firstResponder === view)
        return [
            DebugSurfaceHandle(
                id: id.uuidString,
                title: workspace.name,
                workingDirectory: workspace.worktreePath,
                focused: focused,
                readText: { [weak view] scrollback in view?.debugReadText(scrollback: scrollback) },
                sendText: { [weak view] text, submit in view?.debugSendText(text, submit: submit) },
                sendKeys: { [weak view] text in view?.debugSendKeys(text) },
                sendKey: { [weak view] text, mods in view?.debugSendKey(text, mods: mods) },
                sendAction: { [weak view] name in view?.debugSendAction(name) },
                mouseMove: { [weak view] x, y in view?.debugMouseMove(x: x, y: y) },
                geometry: { [weak view] in
                    view?.debugGeometry() ?? DebugSurfaceGeometry(
                        columns: 0, rows: 0, widthPixels: 0, heightPixels: 0,
                        cellWidthPixels: 0, cellHeightPixels: 0,
                        boundsWidth: 0, boundsHeight: 0, backingWidth: 0, backingHeight: 0,
                        contentScaleX: 0, contentScaleY: 0, backingScaleFactor: 0)
                },
                focus: { [weak window, weak view] in window?.makeFirstResponder(view) },
                window: window),
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
#endif
