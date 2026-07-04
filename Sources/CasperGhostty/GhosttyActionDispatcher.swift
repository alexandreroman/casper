import CasperCore
import Foundation

/// The extension seam for libghostty app-level actions (new tab/window/split, close).
/// A handler claims an action by returning true; unclaimed actions fall back to
/// libghostty's own handling.
public protocol GhosttyActionHandler {
    func handle(_ action: GhosttyAction) -> Bool
}

/// Default handler: logs app-level actions that have no Casper feature yet, as
/// explicit greppable no-ops, and claims none of them.
public struct LoggingActionHandler: GhosttyActionHandler {
    public init() {}
    public func handle(_ action: GhosttyAction) -> Bool {
        switch action {
        case .newTab, .newWindow, .newSplit, .closeTab, .closeWindow:
            #if DEBUG
            CasperLog.ghostty.debug("action-dispatch: no handler for \(String(describing: action), privacy: .public)")
            #endif
        default:
            break
        }
        return false
    }
}
