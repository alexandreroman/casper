import GhosttyKit
import XCTest
@testable import CasperGhostty

final class GhosttyRuntimeTrampolineTests: XCTestCase {
    /// The real libghostty `action_cb` typedef carries no `userdata` argument, so
    /// the C trampoline recovers the runtime via `ghostty_app_userdata(app)` and
    /// forwards to `handleAction(_:)`. That handoff needs a live app, so here we
    /// test the pure routing unit directly: a decoded action reaches `onAction`.
    func testHandleActionRoutesDecodedActionToOnAction() {
        // A runtime built without touching libghostty app creation.
        let runtime = GhosttyRuntime.forTesting()
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertEqual(received, .render)
    }

    func testHandleActionReturnsTrueWithoutObserver() {
        let runtime = GhosttyRuntime.forTesting()

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        XCTAssertTrue(runtime.handleAction(action))
    }

    /// The default `actionHandler` (`LoggingActionHandler`) claims no app-level
    /// action, so `handleAction` must still fall through to `onAction`.
    func testHandleActionFallsThroughToOnActionWhenHandlerDoesNotClaim() {
        let runtime = GhosttyRuntime.forTesting()
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_TAB

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertEqual(received, .newTab)
    }

    /// A handler that claims the action (returns `true`) must suppress the
    /// existing `onAction` fallback for it.
    func testHandleActionSuppressesOnActionWhenHandlerClaims() {
        let runtime = GhosttyRuntime.forTesting()
        runtime.actionHandler = ClaimingActionHandler(claimed: .newTab)
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_TAB

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertNil(received)
    }

    /// `SET_TITLE` and `SHOW_CHILD_EXITED` are delivered surface-locally and must
    /// terminate inside the trampoline, never reaching the runtime — otherwise the
    /// payload gets decoded a second time on the action hot path (OSC titles fire on
    /// every shell prompt). Driving a real surface-tagged target needs a live surface,
    /// which is flaky headless, so this pins the branch from its app-tagged side: with
    /// no recoverable view *and* no app to fall back to, the tags must still report
    /// consumed, which only holds if the trampoline returns before the runtime handoff.
    func testSurfaceScopedActionsAreConsumedInsideTheTrampoline() {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP

        for tag in [GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SHOW_CHILD_EXITED] {
            var action = ghostty_action_s()
            action.tag = tag

            XCTAssertTrue(casperGhosttyAction(nil, target, action), "tag \(tag.rawValue) must be consumed")
        }
    }
}

/// Stub `GhosttyActionHandler` that claims exactly one action, for testing
/// `handleAction`'s fallback-suppression path.
private struct ClaimingActionHandler: GhosttyActionHandler {
    let claimed: GhosttyAction

    func handle(_ action: GhosttyAction) -> Bool {
        action == claimed
    }
}
