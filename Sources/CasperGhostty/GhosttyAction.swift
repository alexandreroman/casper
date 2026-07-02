import GhosttyKit

/// The direction a new split grows, mapped from `ghostty_action_split_direction_e`.
public enum GhosttySplitDirection: Equatable {
    case right, down, left, up
}

/// A libghostty runtime action, decoded from the C `action_cb` callback into a
/// Swift-native value. `CasperGhostty` handles the surface-level actions
/// (title, pwd, bell, render, notifications); layout actions (split/tab/window)
/// are decoded here but acted on by CasperUI in Plan 5.
public enum GhosttyAction: Equatable {
    case setTitle(String)
    case setTabTitle(String)
    case pwd(String)
    case ringBell
    case render
    case childExited(exitCode: Int32)
    case desktopNotification(title: String, body: String)
    case newSplit(GhosttySplitDirection)
    case newTab
    case newWindow
    case closeTab
    case closeWindow
    /// Any action tag CasperGhostty does not model yet; carries the raw tag so
    /// callers can log or extend without this enum being a bottleneck.
    case other(tag: UInt32)

    /// Total decode: every tag maps to a case (`.other` for the unmodeled).
    public static func decode(_ c: ghostty_action_s) -> GhosttyAction {
        switch c.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return .setTitle(Self.string(c.action.set_title.title))
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            return .setTabTitle(Self.string(c.action.set_tab_title.title))
        case GHOSTTY_ACTION_PWD:
            return .pwd(Self.string(c.action.pwd.pwd))
        case GHOSTTY_ACTION_RING_BELL:
            return .ringBell
        case GHOSTTY_ACTION_RENDER:
            return .render
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Truncating (not trapping) conversion: exit_code is external C data,
            // and `Int32(UInt32)` would crash for any value above Int32.max.
            return .childExited(exitCode: Int32(truncatingIfNeeded: c.action.child_exited.exit_code))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return .desktopNotification(
                title: Self.string(c.action.desktop_notification.title),
                body: Self.string(c.action.desktop_notification.body))
        case GHOSTTY_ACTION_NEW_SPLIT:
            return .newSplit(Self.direction(c.action.new_split))
        case GHOSTTY_ACTION_NEW_TAB:
            return .newTab
        case GHOSTTY_ACTION_NEW_WINDOW:
            return .newWindow
        case GHOSTTY_ACTION_CLOSE_TAB:
            return .closeTab
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return .closeWindow
        default:
            return .other(tag: c.tag.rawValue)
        }
    }

    private static func string(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    private static func direction(
        _ d: ghostty_action_split_direction_e
    ) -> GhosttySplitDirection {
        switch d {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        // Unrecognized/future direction values fall back to `.right`, the same
        // safe-default rationale as `.other(tag:)` for unmodeled action tags.
        default: return .right
        }
    }
}
