import CasperCore
import CasperGhostty
import Dispatch

/// Bridges libghostty layout actions to `AppModel` mutations. Returns `true` for
/// the actions it consumes so the runtime does not also fall through to
/// `onAction`.
///
/// Two of libghostty's default keybinds are remapped onto the nearest thing Casper
/// has, because Casper's window model is not Ghostty's: ⌘T ("new tab") makes a
/// split, since Casper has no tabs, and ⌘N ("new window") opens the New Space
/// panel, since Casper has a single window and the honest meaning of "new" at that
/// level is a new project. Claiming them here is also what lets the keystroke work
/// at all while a terminal is focused: `GhosttySurfaceView.performKeyEquivalent`
/// runs ahead of the main menu and reports the combo as consumed, so an action left
/// unclaimed here would take the shortcut away from the menu item without doing
/// anything in its place.
struct LayoutActionHandler: GhosttyActionHandler {
    weak var model: AppModel?

    func handle(_ action: GhosttyAction) -> Bool {
        guard let model else { return false }
        switch action {
        case .newTab:
            MainActor.assumeIsolated { model.applyNewTerminal() }
            return true
        case .newSplit(let direction):
            MainActor.assumeIsolated { model.applyNewSplit(map(direction)) }
            return true
        case .newWindow:
            // The one case that is deferred rather than run inline. This action is
            // dispatched from inside `ghostty_surface_key`, i.e. the middle of
            // libghostty's own key processing, and "New Space…" opens an `NSSavePanel`
            // whose `runModal()` does not return until the user is done with it. Running
            // it here would hold libghostty's tick open for that whole time — and the
            // repository creation that follows the panel with it. `DispatchQueue.main`
            // is the hop that *guarantees* the block cannot run inside the current tick,
            // which is the rule `casperGhosttyConfirmReadClipboard` follows for the same
            // hazard (`MainRunLoop.perform` is explicitly not a substitute here: it runs
            // under modal run loops by design). The cases around this one stay inline
            // because they are bounded model mutations that spin no nested run loop.
            DispatchQueue.main.async { [weak model] in
                MainActor.assumeIsolated { model?.presentCreateSpacePanel() }
            }
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
