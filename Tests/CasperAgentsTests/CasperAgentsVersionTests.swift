import XCTest
@testable import CasperAgents

final class CasperAgentsVersionTests: XCTestCase {
    func testModuleVersionIsSet() {
        XCTAssertEqual(casperAgentsVersion, "0.1.0")
    }
}
