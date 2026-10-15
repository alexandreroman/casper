import CasperCore
import CasperGhostty
import Dispatch

/// Bridges libghostty layout actions to `AppModel` mutations. Returns `true` for
/// the actions it consumes so the runtime does not also fall through to
/// `onAction`.
///
/// Two of libghostty's default keybinds are remapped onto the nearest thing Casper
/// has, because Casper's window model is not Ghostty's: ⌘T ("new tab") makes a
/// split, since Casper has no tabs, and ⌘N ("new window") runs the Workspace menu's
/// New Workspace…, which carries ⌘N in the menu bar too — Casper has a single
/// window, and the new thing a user reaches for most is a workspace. Claiming them
/// here is also what lets the keystroke work at all while a terminal is focused:
/// `GhosttySurfaceView.performKeyEquivalent` runs ahead of the main menu and reports
/// the combo as consumed, so an action left unclaimed here would take the shortcut
/// away from the menu item without doing anything in its place. New Space…'s ⇧⌘N
/// needs no such claim: libghostty binds nothing to it, so it falls through to the
/// menu.
struct LayoutActionHandler: GhosttyActionHandler {
    weak var model: AppModel?

    func handle(_ action: GhosttyAction) -> Bool {
        guard let model else { return false }
        switch action {
        case .newTab:
            MainActor.assumeIsolated { model.applyNewTerminal() }
            return true
        case .newSplit(let direction):
            MainActor.assumeIsolated { model.applyNewSplit(direction) }
            return true
        case .newWindow:
            // The one case that is deferred rather than run inline, and through two hops
            // because "New Workspace…" opens a name prompt whose `runModal()` does not
            // return until the user is done with it.
            //
            // 1. `DispatchQueue.main` gets out of libghostty's tick. This action is
            //    dispatched from inside `ghostty_surface_key`, the middle of libghostty's
            //    own key processing, and running the prompt there would hold that tick
            //    open for as long as the prompt is up. The main queue *guarantees* the
            //    block cannot run inside the current tick, which is the rule
            //    `casperGhosttyConfirmReadClipboard` follows for the same hazard.
            // 2. `MainRunLoop.perform` gets the modal out of the main-queue drain. A
            //    `runModal()` entered from a main-queue block starves the main queue for
            //    as long as it runs — libdispatch never re-enters the drain — so every
            //    `@MainActor` task, `DispatchQueue.main` refresh and debouncer would wait
            //    out the prompt, and AppKit, which focuses the prompt's text field from
            //    a main-queue block, would leave it unfocused. A run-loop block runs on a
            //    later pass of the loop, once the drain has returned.
            //
            // Hop 2 alone would not do: a run-loop block only promises some later pass of
            // the loop, which a nested loop entered from within the tick already
            // satisfies. Scheduled from inside hop 1, it is only enqueued once the tick
            // is over, so that re-entrancy hazard cannot arise. The cases around this one
            // stay inline because they are bounded model mutations that spin no nested
            // run loop.
            //
            // Claimed even when there is no Git Space to create in: the presenter then
            // no-ops, exactly like the disabled menu item.
            DispatchQueue.main.async { [weak model] in
                MainRunLoop.perform { [weak model] in
                    MainActor.assumeIsolated { model?.presentNewWorkspacePanel() }
                }
            }
            return true
        case .closeTab:
            MainActor.assumeIsolated { model.applyCloseFocusedSurface() }
            return true
        default:
            return false
        }
    }
}
