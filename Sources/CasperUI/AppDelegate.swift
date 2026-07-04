import AppKit
import CasperAgents
import CasperCore
import CasperGhostty
import Foundation

/// Per-user socket under the temp dir, stable across relaunches. No canonical
/// hook socket path constant exists elsewhere in the codebase (unlike the debug
/// channel's `DebugSocketPath`); this is the one source of truth for it, shared
/// between the server and the `CASPER_SOCKET` value injected into surfaces.
enum HookSocketPathProvider {
    static var defaultPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("casper-hooks.sock")
    }
}

/// Carries lifecycle work that a SwiftUI `App` scene does not express: install
/// hooks, start the hook socket + heartbeat, set the AppKit menu, and save on
/// terminate. Shares the one `AppModel` with the SwiftUI scene via
/// `AppModel.shared`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var socketServer: HookSocketServer?
    private var heartbeatTimer: Timer?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        NSApp.mainMenu = buildMainMenu()

        // Global, idempotent hook install; non-blocking on failure.
        do {
            try ClaudeCodeAdapter.install()
        } catch {
            CasperLog.app.failure("hook install failed", error)
        }

        // The Ghostty runtime is created once and shared by every surface.
        do {
            let runtime = try GhosttyRuntime()
            runtime.onAction = { action in
                switch action {
                case .setTitle(let title): NSApp.keyWindow?.title = title
                case .quit: NSApp.terminate(nil)
                case .closeWindow: NSApp.keyWindow?.performClose(nil)
                default: break
                }
            }
            model.runtime = runtime
            runtime.actionHandler = LayoutActionHandler(model: model)
        } catch {
            CasperLog.ghostty.failure("ghostty init failed", error)
            NSApp.terminate(nil)
            return
        }

        // Per-surface env inputs.
        model.casperDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })

        // Hook socket: hop to the main actor, then route into the model.
        let socketPath = HookSocketPathProvider.defaultPath
        let server = HookSocketServer(socketPath: socketPath, onMessage: { message in
            Task { @MainActor in AppModel.shared.handleHookMessage(message, now: Date()) }
        })
        do {
            try server.start()
            self.socketServer = server
            model.socketPath = socketPath
        } catch {
            CasperLog.app.failure("hook socket failed to start", error)
        }

        // Heartbeat timer (main run loop).
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.tickHeartbeat(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.heartbeatTimer = timer

        // Debug channel for the `debug-casper` harness. Compiled out of release
        // builds entirely — see the `nm` gating check in the task report.
        #if DEBUG
        let debug = DebugServer(socketPath: DebugSocketPath.default, provider: AppModel.shared)
        do { try debug.start(); self.debugServer = debug }
        catch { CasperLog.debug.error("debug server failed to start: \(String(describing: error))") }
        #endif

        // Bare SPM executable launched from a terminal: macOS does not foreground
        // us automatically, so activate explicitly (mirrors GhosttyDemo).
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        heartbeatTimer?.invalidate()
        socketServer?.stop()  // stop BEFORE the final save (no post-save onMessage)
        #if DEBUG
        debugServer?.stop()
        #endif
        AppModel.shared.flushPendingSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
