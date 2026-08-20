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
    // `NSMenu.delegate` is weak, so the App-menu proxy needs an owner here.
    private var appMenuDelegateProxy: AppMenuDelegateProxy?
    #if DEBUG
    // Temporary freeze-diagnosis scaffolding — see MainThreadHangWatchdog. DEBUG
    // only; remove once the beachball hang is root-caused.
    private var hangWatchdog: MainThreadHangWatchdog?
    private var debugServer: DebugServer?
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Casper is single-window; disabling automatic window tabbing removes the
        // tab-management items AppKit injects into the View menu ("Show Tab Bar",
        // "Show All Tabs") and Window menu ("Show Previous/Next Tab", "Move Tab to
        // Next Window", "Merge All Windows").
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        // Force the app-wide appearance to dark regardless of the system Light/Dark
        // setting. This covers all SwiftUI chrome and AppKit surfaces (menus, panels,
        // Open/Save dialogs). The Ghostty terminal is Metal-rendered with its own
        // palette, so it is unaffected.
        NSApp.appearance = NSAppearance(named: .darkAqua)

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
            // Probe the agent integrations once at launch. Off the main actor, so
            // the seconds it may take on a cold process never delay the first frame.
            model.refreshAgentIntegrations()
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
        let controlPath = model.sessionIdentity.controlSocketPath()
        let control = ControlServer(socketPath: controlPath, model: model)
        do {
            try control.start()
            self.controlServer = control
            model.controlSocketPath = controlPath
        } catch {
            CasperLog.app.failure("control server failed to start", error)
        }

        setupNotifications()

        // Sparkle schedules its own periodic checks once started, so launch is the
        // only place it has to be kicked off. It stays inert in dev builds — see
        // SoftwareUpdater for the bundle-configuration gate.
        SoftwareUpdater.shared.start()

        #if DEBUG
        // Temporary main-thread hang diagnostics, compiled out of release builds.
        // On a detected freeze it dumps a `sample` stack trace under
        // ~/Library/Logs/Casper/ and surfaces a notification. The capture callback
        // fires on a background thread, so hop to the main actor before touching
        // UserNotifications.
        let watchdog = MainThreadHangWatchdog { dumpFileURL in
            Task { @MainActor in
                AppModel.shared.deliverNotification(
                    "Casper UI freeze captured", dumpFileURL.lastPathComponent, UUID(), .active)
            }
        }
        watchdog.start()
        hangWatchdog = watchdog
        #endif

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
        hangWatchdog?.stop()
        debugServer?.stop()
        #endif
        AppModel.shared.flushPendingSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillUpdate(_ notification: Notification) { resyncMainMenu() }

    func applicationDidUpdate(_ notification: Notification) { resyncMainMenu() }

    /// Re-apply Casper's AppKit-side menu-bar fixups, resolving the App menu once
    /// for the two steps scoped to it.
    ///
    /// Deliberately driven from BOTH `applicationWillUpdate` and
    /// `applicationDidUpdate`: SwiftUI rebuilds `NSApp.mainMenu` in several passes
    /// spanning ~250 ms, and the two hooks fire at different points relative to the
    /// menu being drawn, so either one alone loses the race and the re-injected
    /// stubs render in the gap.
    ///
    /// Both hooks fire after essentially every event AppKit processes — mouse-moved
    /// included, so this runs while the user is merely typing in a terminal. Everything
    /// below therefore reads the menus through `item(at:)` and `numberOfItems`: `items`
    /// bridges a whole ObjC array into a fresh Swift array on each access, and each of
    /// the three steps used to ask for one.
    private func resyncMainMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let appMenu = mainMenu.item(at: 0)?.submenu {
            installAppMenuDelegateProxy(on: appMenu)
            // Safety net for Services re-injections that happen while no menu is
            // being opened; the delegate proxy is what strips it in time.
            stripServicesItems(fromAppMenu: appMenu)
        }
        stripEmptyTopLevelMenus(in: mainMenu)
    }

    /// Strip every empty top-level menu from the main menu.
    ///
    /// SwiftUI's `.commands` cannot remove an entire top-level menu — an emptied
    /// `CommandGroup` (Casper empties `.textFormatting` and `.help`) leaves the
    /// menu's title on the bar with no items. SwiftUI resyncs the menu in multiple
    /// passes, re-inserting those empty Format/Help stubs; stripping on both the
    /// will- and did-update passes minimizes the window in which the stubs are
    /// visible, which is what produced the intermittent menu-bar flicker.
    ///
    /// This is safe and terminating: it never touches File/Edit/View/App/Window
    /// (always populated), so it cannot make a real menu disappear, and once the
    /// stubs are removed a subsequent pass finds nothing to strip. Matching empty
    /// submenus (rather than titles) keeps it locale-independent.
    private func stripEmptyTopLevelMenus(in mainMenu: NSMenu) {
        // Walked backwards by index so removals don't disturb the positions still to be
        // visited — the price of not snapshotting `items` on every pass.
        for index in stride(from: mainMenu.numberOfItems - 1, through: 0, by: -1)
        where mainMenu.item(at: index)?.submenu?.numberOfItems == 0 {
            mainMenu.removeItem(at: index)
        }
    }

    /// Keep `AppMenuDelegateProxy` installed as the App menu's delegate.
    ///
    /// This is what actually removes Services *before the user can see it* — see
    /// `stripServicesItems(fromAppMenu:)` for why the update hooks alone cannot.
    /// SwiftUI owns the App menu's delegate and swaps it on some resyncs, so the
    /// check runs on every update pass: whenever the current delegate is not our
    /// proxy, the new one gets wrapped in a fresh proxy. A proxy is never wrapped
    /// in another proxy — the delegate it was already forwarding to is reused.
    private func installAppMenuDelegateProxy(on appMenu: NSMenu) {
        // Written as `if let` rather than comparing the two optionals: `nil === nil`
        // is true, which would skip the very first install on a delegate-less menu.
        if let installed = appMenuDelegateProxy, appMenu.delegate === installed { return }

        let current = appMenu.delegate
        let original = (current as? AppMenuDelegateProxy)?.original ?? current
        let proxy = AppMenuDelegateProxy(wrapping: original)
        appMenu.delegate = proxy
        appMenuDelegateProxy = proxy

        let originalName = original.map { String(describing: type(of: $0)) } ?? "none"
        CasperLog.app.debug("installed App-menu delegate proxy over \(originalName, privacy: .public)")
    }

    /// Tell libghostty the app regained focus (cursor blink, focus animation),
    /// release the Dock bounce the user just answered, and re-probe the agent
    /// integrations — the user may have installed or updated a plugin in the app
    /// they just came back from. Throttled, so the probe's three login shells do
    /// not run on every Cmd-Tab.
    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.runtime?.setAppFocus(true)
        AppModel.shared.releaseDockBounce()
        AppModel.shared.refreshAgentIntegrationsIfStale()
    }

    /// Tell libghostty the app lost focus. Complementary to occlusion — this does
    /// not pause rendering, only quiets focus-driven work. Also releases the Dock
    /// bounce, so nothing an active Casper may have requested outlives its activation.
    func applicationDidResignActive(_ notification: Notification) {
        AppModel.shared.runtime?.setAppFocus(false)
        AppModel.shared.releaseDockBounce()
    }
}

/// Wraps the App menu's own `NSMenuDelegate` (SwiftUI installs one) so Casper can
/// strip Services from `menuNeedsUpdate(_:)`, while every other delegate message
/// still reaches SwiftUI untouched.
///
/// `menuNeedsUpdate(_:)` is the only hook AppKit guarantees runs *between* the
/// click and the menu being drawn, which is precisely what the strip needs — see
/// `stripServicesItems(fromAppMenu:)`.
///
/// The proxy holds the original weakly (SwiftUI owns it; this only borrows it) and
/// is itself retained by `AppDelegate`, so nothing here forms a retain cycle.
private final class AppMenuDelegateProxy: NSObject, NSMenuDelegate {
    private(set) weak var original: NSMenuDelegate?

    init(wrapping original: NSMenuDelegate?) {
        self.original = original
        super.init()
    }

    @MainActor
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Order matters: the original delegate is free to re-assert this menu's
        // contents here, so Casper's strip has to run after it, never before.
        original?.menuNeedsUpdate?(menu)
        stripAndLog(menu, hook: "needsUpdate")
    }

    /// AppKit's second pre-display callback, kept as a belt-and-braces pass: it is
    /// the last point before the menu is drawn, so it also catches anything that
    /// re-inserts Services between `menuNeedsUpdate(_:)` and the menu opening.
    @MainActor
    func menuWillOpen(_ menu: NSMenu) {
        original?.menuWillOpen?(menu)
        stripAndLog(menu, hook: "willOpen")
    }

    /// Kept on purpose: the before/after dump is the only way to observe the
    /// re-inject/strip ordering without re-instrumenting the app, and this bug class
    /// recurs. A "before" list still carrying Services shows the item survived until
    /// display time; the "after" list proves the strip won the race.
    @MainActor
    private func stripAndLog(_ menu: NSMenu, hook: String) {
        let before = menu.items.map(\.title).joined(separator: " | ")
        stripServicesItems(fromAppMenu: menu)
        let after = menu.items.map(\.title).joined(separator: " | ")
        CasperLog.app.debug("""
            App menu \(hook, privacy: .public): \
            before=[\(before, privacy: .public)] after=[\(after, privacy: .public)]
            """)
    }

    // Everything this proxy does not implement itself must behave exactly as if
    // SwiftUI's delegate were still installed — hence plain ObjC forwarding.
    // `responds(to:)` has to agree with it, or AppKit's optional-method probes ask
    // the wrong object and the menu breaks.
    override func forwardingTarget(for selector: Selector!) -> Any? {
        original
    }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return original?.responds(to: selector) ?? false
    }
}

/// Remove the Services submenu from the App menu.
///
/// Casper does not expose Services, and SwiftUI offers no `CommandGroup` for them:
/// the App menu's Services entry is AppKit's own (it fills `NSApp.servicesMenu`),
/// so the removal has to happen in AppKit. SwiftUI re-asserts the whole native menu
/// on every scene-lifecycle resync, which re-injects Services, so a one-shot
/// removal at launch does not hold.
///
/// **Why `applicationWillUpdate` / `applicationDidUpdate` cannot be the only
/// callers.** Both hooks run *after* AppKit has already drawn the menu, so on the
/// pass that matters they lose the race by construction. Logging every removal on
/// a long-running instance showed exactly that: a strip at launch (12:47:01), then
/// one per menu opening (13:55:42, 13:55:56, 13:56:06) — and a screenshot taken
/// during those openings shows Services present and expanded. The item was removed
/// every single time, always too late to matter. The two hooks are kept as a safety
/// net for re-injections that happen with no menu open (they also feed
/// `stripEmptyTopLevelMenus()` a final menu), but the removal that the user
/// actually sees is the one driven from `AppMenuDelegateProxy.menuNeedsUpdate(_:)`,
/// which AppKit calls immediately before displaying the menu.
///
/// Detection deliberately does NOT go through `NSApp.servicesMenu`. Logging that
/// property on every pass showed it is not a mirror of the item's presence: it
/// flips back to non-nil milliseconds after being cleared, while no Services item
/// is in the menu — both AppKit and SwiftUI write to it. So gating on it
/// (`guard let servicesMenu = NSApp.servicesMenu … else { return }`) turns the
/// strip into a one-shot: a resync that re-inserts the item while the property
/// happens to be nil is never cleaned up again.
///
/// The item is matched structurally instead: in the App menu, Services is the only
/// entry carrying a submenu (About / Settings / Hide / Hide Others / Show All /
/// Quit are all plain items — verified by dumping the menu on every pass). That
/// criterion is locale-independent (macOS localizes "Services"),
/// identity-independent, idempotent, and confined to the App menu.
/// `NSApp.servicesMenu` is still cleared afterwards so AppKit stops feeding the
/// orphaned submenu — but as an effect, never as a precondition.
@MainActor
private func stripServicesItems(fromAppMenu appMenu: NSMenu) {
    // Backwards by index, like `stripEmptyTopLevelMenus`: this runs on every update
    // pass, and the overwhelmingly common outcome is "nothing to remove", which must
    // not cost an array bridge plus a `filter` allocation.
    var removedAny = false
    for index in stride(from: appMenu.numberOfItems - 1, through: 0, by: -1) {
        guard let item = appMenu.item(at: index), item.submenu != nil else { continue }
        appMenu.removeItem(at: index)
        removedAny = true
        CasperLog.app.debug("removed App-menu submenu item: \(item.title, privacy: .public)")
    }
    guard removedAny else { return }
    NSApp.servicesMenu = nil
    // AppKit brackets the Services item with separators, so removing it leaves two
    // adjacent ones behind.
    normalizeSeparators(in: appMenu)
}

/// Collapse runs of consecutive separators and drop a leading or trailing one, so a
/// removed item does not leave a visible gap behind.
private func normalizeSeparators(in menu: NSMenu) {
    for index in stride(from: menu.numberOfItems - 1, through: 0, by: -1) {
        guard menu.item(at: index)?.isSeparatorItem == true else { continue }
        let isFirstItem = index == 0
        let isLastItem = index == menu.numberOfItems - 1
        let followsAnotherSeparator = index > 0 && menu.item(at: index - 1)?.isSeparatorItem == true
        if isFirstItem || isLastItem || followsAnotherSeparator {
            menu.removeItem(at: index)
        }
    }
}
