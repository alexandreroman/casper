import AppKit
import CasperCore
import CasperGhostty
import Foundation

/// Carries lifecycle work that a SwiftUI `App` scene does not express: start the
/// control server, set the AppKit menu, and save on terminate. Shares the one
/// `AppModel` with the SwiftUI scene via `AppModel.shared`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controlServer: ControlServer?
    private var keyWindowObserver: NSObjectProtocol?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        NSApp.mainMenu = buildMainMenu()

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

        // Release control socket: the `casper` CLI's command channel, distinct
        // from the DEBUG-only debug channel below — this one ships in release.
        let controlPath = ControlSocketPath.default
        let control = ControlServer(socketPath: controlPath, model: model)
        do {
            try control.start()
            self.controlServer = control
            model.controlSocketPath = controlPath
        } catch {
            CasperLog.app.failure("control server failed to start", error)
        }

        // When a window becomes key (the app returns to the foreground), dismiss
        // the attention bubble of the now-focused workspace. Mirrors the
        // selection-time clear in `selectWorkspace`.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppModel.shared.clearNotificationForFocusedWorkspace() }
        }

        // Debug channel for the `debug-casper` harness. Compiled out of release
        // builds entirely — see the `nm` gating check in the task report.
        #if DEBUG
        let debug = DebugServer(socketPath: DebugSocketPath.default, provider: AppModel.shared)
        do { try debug.start(); self.debugServer = debug }
        catch { CasperLog.debug.error("debug server failed to start: \(String(describing: error))") }
        #endif

        // Bare SPM executable launched from a terminal: macOS does not foreground
        // us automatically, so activate explicitly.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        controlServer?.stop()
        #if DEBUG
        debugServer?.stop()
        #endif
        AppModel.shared.flushPendingSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
