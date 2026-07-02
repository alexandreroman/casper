import XCTest
@testable import CasperGhostty

final class SmokeTests: XCTestCase {
    func testModuleLinksAndExposesPin() {
        XCTAssertEqual(CasperGhostty.pinnedGhosttyVersion, "v1.3.1")
    }
}
