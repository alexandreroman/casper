import XCTest
@testable import CasperCore

final class SmokeTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(casperCoreVersion.isEmpty)
    }
}
