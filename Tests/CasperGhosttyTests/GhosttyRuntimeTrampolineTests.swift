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
        action.tag = GHOSTTY_ACTION_RING_BELL

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertEqual(received, .ringBell)
    }

    func testHandleActionReturnsTrueWithoutObserver() {
        let runtime = GhosttyRuntime.forTesting()

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL

        XCTAssertTrue(runtime.handleAction(action))
    }
}
