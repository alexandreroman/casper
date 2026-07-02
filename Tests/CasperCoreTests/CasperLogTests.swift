import XCTest
@testable import CasperCore

final class CasperLogTests: XCTestCase {
    func testSubsystemIsStable() {
        // The debug-casper skill's `log` predicate depends on this exact value.
        XCTAssertEqual(CasperLog.subsystem, "com.github.alexandreroman.casper")
    }
}
