import AppKit

/// Watches for Cmd being held ≥250ms to reveal the sidebar's `Cmd+N` shortcut
/// hints (see `WorkspaceRow`), handles `Cmd+1…9` itself so the workspace switch
/// works even before the hint appears, and mirrors a bare Option press onto
/// `AppModel.optionKeyHeld` (which turns the title bar's Merge chip into a
/// Delete chip while it is down). Installed once from
/// `AppDelegate.applicationDidFinishLaunching` — a local (not global) `NSEvent`
/// monitor, so this only fires while a Casper window is key and needs no
/// Accessibility permission.
@MainActor
final class WorkspaceShortcutKeyMonitor {
    /// Physical digit keys (ANSI virtual keycodes) mapped to their digit, for
    /// both the number row and the numeric keypad. Matching by physical keycode
    /// means each digit has one position per cluster — a top-row key and its
    /// numeric-keypad counterpart both switch to the same workspace.
    private static let digitKeyCodes: [UInt16: Int] = [
        // Number row.
        0x12: 1, 0x13: 2, 0x14: 3, 0x15: 4, 0x17: 5,
        0x16: 6, 0x1A: 7, 0x1C: 8, 0x19: 9,
        // Numeric keypad (kVK_ANSI_Keypad1…9).
        0x53: 1, 0x54: 2, 0x55: 3, 0x56: 4, 0x57: 5,
        0x58: 6, 0x59: 7, 0x5B: 8, 0x5C: 9,
    ]

    private let model: AppModel
    private let tracker: CommandHoldTracker
    // `nonisolated(unsafe)` is safe here: both are only ever mutated from
    // `start()` on the main actor, and by the time `deinit` runs no other
    // reference to the object exists, so there's no concurrent access to race
    // with. This lets `deinit` read them without a main-actor hop — avoiding
    // the `isolated deinit` back-deployment shim that SIGABRTs on the CI runner.
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var resignActiveObserver: NSObjectProtocol?

    init(model: AppModel, holdDuration: TimeInterval = 0.25) {
        self.model = model
        self.tracker = CommandHoldTracker(holdDuration: holdDuration) { show in
            // Guarded write: the tracker reports every release, including the many that
            // never revealed anything (any Cmd-then-Cmd+Shift combo releases a hold that
            // was still pending). `showWorkspaceShortcutHints` is `@Observable`, and an
            // unconditional write notifies every sidebar row even when the value is
            // unchanged — the same reason `AppModel.refreshMenuFlags` guards its own.
            guard model.showWorkspaceShortcutHints != show else { return }
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
                // Same reasoning for Option: Cmd+Tabbing away while holding it
                // would otherwise leave the chip stuck on Delete.
                self?.setOptionKeyHeld(false)
            }
        }
    }

    deinit {
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
        // unrelated shortcut like Cmd+Shift+D ("Split Down", `CasperCommands`
        // in MenuCommands.swift).
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.type {
        case .flagsChanged:
            if relevantFlags == .command {
                tracker.commandKeyDown()
            } else {
                tracker.commandKeyUp()
            }
            // Bare Option only, for the same reason: Cmd+Option and Shift+Option
            // belong to other shortcuts, and morphing the Merge chip mid-combo
            // would be noise.
            setOptionKeyHeld(relevantFlags == .option)
            return event
        case .keyDown:
            // Match the physical key position, not the character: on an AZERTY
            // layout the number-row keys emit "& é …" unshifted, so matching by
            // `charactersIgnoringModifiers` would miss Cmd+1…9 there.
            guard relevantFlags == .command, let digit = Self.digitKeyCodes[event.keyCode]
            else {
                return event
            }
            // The switch itself reports whether a workspace carries that number, so the
            // event is consumed only when it did something — and the numbering is built
            // once instead of once to check and once to look up.
            return model.selectWorkspace(atShortcutNumber: digit) ? nil : event
        default:
            return event
        }
    }

    /// Guarded write, like the hint flag above: `optionKeyHeld` is `@Observable`
    /// and EVERY modifier transition lands here, so an unconditional write would
    /// re-render the workspace toolbar on each Shift, Control and Cmd press too.
    private func setOptionKeyHeld(_ held: Bool) {
        guard model.optionKeyHeld != held else { return }
        model.optionKeyHeld = held
    }
}
