import XCTest
@testable import CasperUI

final class AgentDetectionCadenceTests: XCTestCase {
    func testVisibleUsesFastCadence() {
        XCTAssertEqual(
            AppModel.agentDetectionInterval(isWindowVisible: true), .milliseconds(250))
    }

    func testHiddenUsesSlowCadence() {
        // Hidden ⇒ throttle, but never stop (background notifications still fire).
        let hidden = AppModel.agentDetectionInterval(isWindowVisible: false)
        XCTAssertEqual(hidden, .milliseconds(1000))
        XCTAssertGreaterThan(hidden, AppModel.agentDetectionInterval(isWindowVisible: true))
    }
}
