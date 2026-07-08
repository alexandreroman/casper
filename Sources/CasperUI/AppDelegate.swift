import AppKit
import CasperCore
import CasperGhostty
import Foundation
import UserNotifications

/// Carries lifecycle work that a SwiftUI `App` scene does not express: start the
/// control server, set the AppKit menu, and save on terminate. Shares the one
/// `AppModel` with the SwiftUI scene via `AppModel.shared`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {
    private var controlServer: ControlServer?
    private var keyWindowObserver: NSObjectProtocol?
    private var workspaceShortcutMonitor: WorkspaceShortcutKeyMonitor?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        // Force the app-wide appearance to dark regardless of the system Light/Dark
        // setting. This covers all SwiftUI chrome and AppKit surfaces (menus, panels,
        // Open/Save dialogs). The Ghostty terminal is Metal-rendered with its own
        // palette, so it is unaffected.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // buildMainMenu() yields App(0)/Edit(1)/Window(2); insert File before Edit
        // and View after Edit to land on App, File, Edit, View, Window.
        NSApp.mainMenu = buildMainMenu()
        NSApp.mainMenu?.insertItem(model.fileMenuItem(), at: 1)
        NSApp.mainMenu?.insertItem(model.viewMenuItem(), at: 3)

        let shortcutMonitor = WorkspaceShortcutKeyMonitor(model: model)
        shortcutMonitor.start()
        workspaceShortcutMonitor = shortcutMonitor

        // The Ghostty runtime is created once and shared by every surface.
        do {
            let runtime = try GhosttyRuntime()
            runtime.onAction = { action in
                switch action {
                case .openURL(let string):
                    if let url = URL(string: string) { NSWorkspace.shared.open(url) }
                case .quit: NSApp.terminate(nil)
                case .closeWindow: NSApp.keyWindow?.performClose(nil)
                default: break
                }
            }
            model.runtime = runtime
            runtime.actionHandler = LayoutActionHandler(model: model)
            // Terminal-scraping agent-state detection is GUI-only, so start its
            // timer here (never from `AppModel.init`, which also runs in tests).
            model.startAgentDetection()
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
        let controlPath = ControlSocketPath.listenPath(for: model.sessionIdentity)
        let control = ControlServer(socketPath: controlPath, model: model)
        do {
            try control.start()
            self.controlServer = control
            model.controlSocketPath = controlPath
        } catch {
            CasperLog.app.failure("control server failed to start", error)
        }

        setupNotifications()

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
        let debug = DebugServer(socketPath: DebugSocketPath.listenPath(for: AppModel.shared.sessionIdentity),
                                provider: AppModel.shared)
        do { try debug.start(); self.debugServer = debug }
        catch { CasperLog.debug.error("debug server failed to start: \(String(describing: error))") }
        #endif

        // Bare SPM executable launched from a terminal: macOS does not foreground
        // us automatically, so activate explicitly.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Register as the notification delegate and request authorization once, at
    /// launch. Without an explicit `requestAuthorization` call macOS silently drops
    /// every `UNNotificationRequest`, so this is what makes `casper notify` visible.
    private func setupNotifications() {
        // `UNUserNotificationCenter.current()` aborts (does not no-op) when the
        // process has no bundle identifier — e.g. the bare `swift run` executable
        // under `make dev`. Same guard the `deliverNotification` closure uses.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                CasperLog.app.failure("notification authorization request failed", error)
            } else if !granted {
                // Not an error, but worth a diagnostic trail: with authorization denied,
                // macOS drops every request, so `casper notify` silently does nothing.
                CasperLog.app.debug("notification authorization denied by the user")
            }
        }
    }

    /// Present notifications as banners (with sound) even while Casper is frontmost;
    /// otherwise macOS would suppress them for the foreground app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Route a notification tap back to its workspace. The request identifier is the
    /// workspace id (set by `deliverNotification`), so parsing it here is what lets a
    /// tap select the originating workspace before bringing Casper to the front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Guard on the workspace still existing: `selectWorkspace` sets the selection
        // unconditionally, so tapping a notification for a since-deleted workspace
        // would otherwise leave a dangling selection.
        if let workspaceID = UUID(uuidString: response.notification.request.identifier),
           AppModel.shared.workspace(id: workspaceID) != nil {
            AppModel.shared.selectWorkspace(workspaceID)
        }
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        AppModel.shared.stopAgentDetection()
        controlServer?.stop()
        #if DEBUG
        debugServer?.stop()
        #endif
        AppModel.shared.flushPendingSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
