import XCTest
@testable import CasperGhostty

final class GhosttyActionDispatcherTests: XCTestCase {
    func testLoggingHandlerDoesNotClaimAppActions() {
        let handler = LoggingActionHandler()
        XCTAssertFalse(handler.handle(.newTab))
    }

    func testCustomHandlerClaimsAction() {
        struct Stub: GhosttyActionHandler {
            func handle(_ action: GhosttyAction) -> Bool { action == .newTab }
        }
        XCTAssertTrue(Stub().handle(.newTab))
        XCTAssertFalse(Stub().handle(.newWindow))
    }
}
