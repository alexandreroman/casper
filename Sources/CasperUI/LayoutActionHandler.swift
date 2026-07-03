import CasperCore
import CasperGhostty

/// Bridges libghostty layout actions to `AppModel` layout mutations. Returns
/// `true` for the actions it consumes so the runtime does not also fall through
/// to `onAction`.
struct LayoutActionHandler: GhosttyActionHandler {
    weak var model: AppModel?

    func handle(_ action: GhosttyAction) -> Bool {
        guard let model else { return false }
        switch action {
        case .newTab:
            MainActor.assumeIsolated { model.applyNewTab() }
            return true
        case .newSplit(let direction):
            MainActor.assumeIsolated { model.applyNewSplit(map(direction)) }
            return true
        case .closeTab:
            MainActor.assumeIsolated { model.applyCloseFocusedSurface() }
            return true
        default:
            return false
        }
    }

    private func map(_ d: GhosttySplitDirection) -> GhosttySplitDirectionLike {
        switch d {
        case .right: return .right
        case .down: return .down
        case .left: return .left
        case .up: return .up
        }
    }
}
