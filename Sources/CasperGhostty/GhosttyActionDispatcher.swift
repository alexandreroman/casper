import CasperCore

/// The extension seam for libghostty app-level actions (new tab/window/split, close).
/// A handler claims an action by returning true; unclaimed actions fall back to
/// libghostty's own handling.
public protocol GhosttyActionHandler {
    func handle(_ action: GhosttyAction) -> Bool
}

/// Default handler: logs app-level actions that have no Casper feature yet, as
/// explicit greppable no-ops, and claims none of them.
struct LoggingActionHandler: GhosttyActionHandler {
    func handle(_ action: GhosttyAction) -> Bool {
        // Only `GhosttyRuntime.handleAction`'s gated set ever reaches a handler, so
        // this logs whatever it is given rather than re-enumerating that list.
        #if DEBUG
        CasperLog.ghostty.debug("action-dispatch: no handler for \(String(describing: action), privacy: .public)")
        #endif
        return false
    }
}
