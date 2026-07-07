import AppKit

/// Watches for Cmd being held ≥1s to reveal the sidebar's `Cmd+N` shortcut
/// hints (see `WorkspaceRow`), and handles `Cmd+1…9` itself so the workspace
/// switch works even before the hint appears. Installed once from
/// `AppDelegate.applicationDidFinishLaunching`, the same place `FileMenu`'s
/// menu wiring happens — a local (not global) `NSEvent` monitor, so this only
/// fires while a Casper window is key and needs no Accessibility permission.
@MainActor
final class WorkspaceShortcutKeyMonitor {
    private let model: AppModel
    private let tracker: CommandHoldTracker
    private var eventMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    init(model: AppModel, holdDuration: TimeInterval = 1.0) {
        self.model = model
        self.tracker = CommandHoldTracker(holdDuration: holdDuration) { show in
            model.showWorkspaceShortcutHints = show
        }
    }

    /// Installs the local event monitor. Call once; the monitor is removed in
    /// `deinit`.
    func start() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event) ?? event
        }

        // A local monitor only sees events while Casper is the key app: if the
        // user holds Cmd until hints reveal, then Cmd+Tabs away while still
        // physically holding it, the release `flagsChanged` never reaches us.
        // Force the tracker back to released as soon as we lose active status
        // so the hints don't stay stuck visible indefinitely.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tracker.commandKeyUp()
            }
        }
    }

    // `isolated` (SE-0371): `eventMonitor` is `Any?`, which is not `Sendable`,
    // so a plain (nonisolated) deinit cannot read it on a `@MainActor` class
    // under Swift 6 strict concurrency checking — this hops deinit onto the
    // main actor instead.
    isolated deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    /// Returns the event to let it keep propagating, or `nil` to consume it
    /// (only for a handled `Cmd+digit`). Not `private` so tests can drive it
    /// directly with synthetic `NSEvent`s instead of going through a real
    /// event monitor.
    func handle(_ event: NSEvent) -> NSEvent? {
        // Only bare Cmd (no Shift/Option/Control) triggers the hold-reveal
        // and Cmd+digit switch, so this never fires mid-combo with an
        // unrelated shortcut like Cmd+Shift+D ("Split down", `FileMenu.swift`).
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.type {
        case .flagsChanged:
            if relevantFlags == .command {
                tracker.commandKeyDown()
            } else {
                tracker.commandKeyUp()
            }
            return event
        case .keyDown:
            guard
                relevantFlags == .command,
                let characters = event.charactersIgnoringModifiers,
                characters.count == 1,
                let digit = Int(characters),
                (1...9).contains(digit),
                model.workspaceShortcutNumbers.values.contains(digit)
            else {
                return event
            }
            model.selectWorkspace(atShortcutNumber: digit)
            return nil
        default:
            return event
        }
    }
}
