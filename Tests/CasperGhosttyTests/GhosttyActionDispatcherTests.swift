import XCTest
@testable import CasperGhostty

final class GhosttyActionDispatcherTests: XCTestCase {
    func testLoggingHandlerDoesNotClaimAppActions() {
        let handler = LoggingActionHandler()
        XCTAssertFalse(handler.handle(.newTab))
    }
}
