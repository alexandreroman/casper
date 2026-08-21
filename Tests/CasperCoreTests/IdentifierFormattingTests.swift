import Foundation
import XCTest
@testable import CasperCore

final class IdentifierFormattingTests: XCTestCase {
    func testCasperIDIsLowercase() {
        let id = UUID()
        XCTAssertEqual(id.casperID, id.casperID.lowercased())
        XCTAssertEqual(id.casperID, id.uuidString.lowercased())
    }

    func testCasperIDRoundTripsThroughUUID() {
        let id = UUID()
        XCTAssertEqual(UUID(uuidString: id.casperID), id)
    }

    /// The uppercase form an older build emitted parses back to the same id, which
    /// is what lets a stale `$CASPER_WORKSPACE_ID` keep resolving.
    func testUppercaseFormParsesToTheSameID() {
        let id = UUID()
        XCTAssertEqual(UUID(uuidString: id.uuidString), UUID(uuidString: id.casperID))
    }
}
