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

private final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let directory: String
    private var window: NSWindow?
    private var runtime: GhosttyRuntime?

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
        } catch {
            CasperLog.ghostty.error("demo failed: \(String(describing: error))")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
