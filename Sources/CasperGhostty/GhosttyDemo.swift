import AppKit
import CasperCore

/// Minimal end-to-end harness: a single window hosting one live terminal
/// surface. This is Plan 4's deliverable and the manual-test entry point; Plan 5
/// replaces it with the real Casper app. Runs the AppKit loop and never returns.
public enum GhosttyDemo {
    @MainActor
    public static func run(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let delegate = DemoDelegate(directory: directory)
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
        // NSApplication.run does not return.
        fatalError("unreachable")
    }
}

@MainActor
private final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let directory: String
    private var window: NSWindow?
    private var runtime: GhosttyRuntime?
    private var surfaceView: GhosttySurfaceView?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif

    init(directory: String) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try GhosttyRuntime()
            runtime.onAction = { action in
                if case .setTitle(let title) = action {
                    // Reflect the shell's title in the window.
                    NSApp.windows.first?.title = title
                }
            }
            self.runtime = runtime

            var config = GhosttySurfaceConfiguration()
            config.workingDirectory = directory

            let view = GhosttySurfaceView(runtime: runtime, configuration: config)
            self.surfaceView = view
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Casper — GhosttyKit demo"
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.window = window
            #if DEBUG
            startDebugServer()
            #endif
        } catch {
            CasperLog.ghostty.error("demo failed: \(String(describing: error), privacy: .public)")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    #if DEBUG
    private func startDebugServer() {
        let server = DebugServer(socketPath: DebugSocketPath.default, provider: self)
        do {
            try server.start()
            self.debugServer = server
        } catch {
            CasperLog.debug.error("debug server failed to start: \(String(describing: error))")
        }
    }
    #endif
}

#if DEBUG
extension DemoDelegate: DebugSurfaceProvider {
    func debugSurfaces() -> [DebugSurfaceHandle] {
        guard let view = surfaceView, view.debugHasSurface else { return [] }
        let window = self.window
        let focused = (window?.firstResponder === view)
        return [
            DebugSurfaceHandle(
                id: "0",
                title: window?.title ?? "casper",
                workingDirectory: directory,
                focused: focused,
                readText: { [weak view] scrollback in view?.debugReadText(scrollback: scrollback) },
                sendText: { [weak view] text in view?.debugSendText(text) },
                columnsRows: { [weak view] in view?.debugColumnsRows() ?? (0, 0) },
                focus: { [weak window, weak view] in window?.makeFirstResponder(view) },
                window: window),
        ]
    }
}
#endif
