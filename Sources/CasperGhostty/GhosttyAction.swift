import GhosttyKit

/// The direction a new split grows, mapped from `ghostty_action_split_direction_e`.
public enum GhosttySplitDirection: Equatable, Sendable {
    case right, down, left, up
}

/// A libghostty runtime action, decoded from the C `action_cb` callback into a
/// Swift-native value. This enum carries the app- and window-scoped actions only:
/// layout actions (splits, tabs, new window, close) dispatched by the runtime's
/// layout handler, plus `.openURL`, `.quit` and `.closeWindow` handled by the
/// AppDelegate's `onAction`. `.render` is decoded but not acted on.
///
/// Surface-scoped actions never reach here: the OSC title, the child exit status,
/// and mouse shape/visibility are intercepted by `casperGhosttyAction` and
/// delivered straight to the target view, which is their only consumer.
///
/// Decoding is total — `decode` maps every remaining tag, unmodeled ones to
/// `.other`.
public enum GhosttyAction: Equatable {
    case render
    /// Emitted on cmd+click of a terminal URL; carries the URL to open.
    case openURL(String)
    case newSplit(GhosttySplitDirection)
    case newTab
    case newWindow
    case closeTab
    case closeWindow
    case quit
    /// Any action tag CasperGhostty does not model yet; carries the raw tag so
    /// callers can log or extend without this enum being a bottleneck.
    case other(tag: UInt32)

    /// Total decode: every tag maps to a case (`.other` for the unmodeled).
    public static func decode(_ c: ghostty_action_s) -> GhosttyAction {
        switch c.tag {
        case GHOSTTY_ACTION_RENDER:
            return .render
        case GHOSTTY_ACTION_OPEN_URL:
            return .openURL(Self.string(c.action.open_url.url, len: c.action.open_url.len))
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
        case GHOSTTY_ACTION_QUIT:
            return .quit
        default:
            return .other(tag: c.tag.rawValue)
        }
    }

    /// Decodes a field (like `open_url.url`) that is NOT null-terminated: reads
    /// exactly `len` bytes and decodes them as UTF-8.
    private static func string(_ ptr: UnsafePointer<CChar>?, len: UInt) -> String {
        guard let ptr else { return "" }
        let bytes = UnsafeBufferPointer(start: ptr, count: Int(len))
        return bytes.withMemoryRebound(to: UInt8.self) { String(decoding: $0, as: UTF8.self) }
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
