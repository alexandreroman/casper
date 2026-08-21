import GhosttyKit

/// The direction a new split grows, mapped from `ghostty_action_split_direction_e`.
public enum GhosttySplitDirection: Equatable, Sendable {
    case right, down, left, up
}

/// A libghostty runtime action, decoded from the C `action_cb` callback into a
/// Swift-native value. Decoding is total (see `decode`), but consumption is
/// partial. The surface-scoped payloads — the OSC title (driving agent-state
/// detection) and the child exit status — are delivered straight to the target
/// view by the `action_cb` trampoline (`updateOSCTitle` / `reportChildExit`) and
/// never travel through the app-level `onAction`, so `.setTitle` and
/// `.childExited` are produced by `decode` without being routed anywhere: a
/// future consumer must hook the view, not `onAction`. Mouse shape/visibility are
/// likewise surface-scoped, and delivered outside this enum. Layout actions
/// (splits, tabs, close) are dispatched by the runtime's layout handler, and the
/// AppDelegate's `onAction` handles `.openURL`, `.quit`, and `.closeWindow`;
/// `.render` and `.newWindow` are decoded but not acted on yet. `.render` and
/// `.childExited` are reserved by the agent-state design (a `.render`-driven
/// re-read replacing the timer poll, and `error` on a non-zero exit code): see
/// `.superpowers/themes/agent-state-detection.md`.
public enum GhosttyAction: Equatable {
    case setTitle(String)
    case render
    case childExited(exitCode: Int32)
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
        case GHOSTTY_ACTION_SET_TITLE:
            return .setTitle(Self.string(c.action.set_title.title))
        case GHOSTTY_ACTION_RENDER:
            return .render
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // The exit is acted on by the `action_cb` trampoline, which delivers it
            // straight to the target view (`reportChildExit`); this decoded copy is
            // routed nowhere. Truncating (not trapping) conversion: exit_code is external
            // C data, and `Int32(UInt32)` would crash for any value above Int32.max.
            return .childExited(exitCode: Int32(truncatingIfNeeded: c.action.child_exited.exit_code))
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

    private static func string(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    /// Length-delimited variant for fields (like `open_url.url`) that are NOT
    /// null-terminated: reads exactly `len` bytes and decodes them as UTF-8.
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
