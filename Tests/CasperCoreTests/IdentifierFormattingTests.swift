import Foundation
import XCTest
@testable import CasperCore

/// Uses a fixed, letter-bearing id: a random `UUID()` can be digits only, and no
/// case assertion can fail on such an id.
final class IdentifierFormattingTests: XCTestCase {
    private let uppercase = "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345"
    private let lowercase = "abcdef01-abcd-4bcd-8bcd-abcdef012345"

    func testCasperIDIsTheLowercaseForm() throws {
        let id = try XCTUnwrap(UUID(uuidString: uppercase))
        XCTAssertEqual(id.casperID, lowercase)
    }

    /// The uppercase form an older build emitted parses back to the same id as the
    /// lowercase one, which is what lets a stale `$CASPER_WORKSPACE_ID` keep
    /// resolving.
    func testBothCasesParseToTheSameID() throws {
        let id = try XCTUnwrap(UUID(uuidString: uppercase))
        XCTAssertEqual(UUID(uuidString: lowercase), id)
        XCTAssertEqual(UUID(uuidString: id.casperID), id)
    }
}
