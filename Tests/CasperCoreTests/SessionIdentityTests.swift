import XCTest
@testable import CasperCore

final class SessionIdentityTests: XCTestCase {
    // Default (unnamed) session — byte-for-byte the historical paths.
    func testDefaultSessionPaths() {
        let id = SessionIdentity.default
        XCTAssertNil(id.name)
        XCTAssertEqual(id.pathSuffix, "")
        XCTAssertEqual(id.layoutFileName, "session.json")
        XCTAssertEqual(id.debugSocketPath, "/tmp/casper-debug.sock")
        XCTAssertEqual(id.controlSocketPath(temporaryDirectory: "/tmp"), "/tmp/casper-control.sock")
        XCTAssertTrue(id.environment.isEmpty)
    }

    func testNamedSessionPaths() {
        let id = SessionIdentity(name: "dev")!
        XCTAssertEqual(id.name, "dev")
        XCTAssertEqual(id.pathSuffix, "-dev")
        XCTAssertEqual(id.layoutFileName, "session-dev.json")
        XCTAssertEqual(id.debugSocketPath, "/tmp/casper-debug-dev.sock")
        XCTAssertEqual(id.controlSocketPath(temporaryDirectory: "/tmp"), "/tmp/casper-control-dev.sock")
        XCTAssertEqual(id.environment, ["CASPER_SESSION": "dev"])
    }

    func testValidation() {
        XCTAssertTrue(SessionIdentity.isValid("dev"))
        XCTAssertTrue(SessionIdentity.isValid("Dev_1.2-3"))
        XCTAssertFalse(SessionIdentity.isValid(""))                 // empty
        XCTAssertFalse(SessionIdentity.isValid("has space"))        // space
        XCTAssertFalse(SessionIdentity.isValid("bad/slash"))        // path separator
        XCTAssertFalse(SessionIdentity.isValid(String(repeating: "a", count: 33))) // too long
        XCTAssertNil(SessionIdentity(name: "bad/slash"))            // failable init rejects
        XCTAssertNotNil(SessionIdentity(name: nil))                 // nil name is valid (default)
    }

    func testParseNoFlagIsDefault() throws {
        XCTAssertEqual(try SessionIdentity.parse(arguments: ["casper"]), .default)
        XCTAssertEqual(try SessionIdentity.parse(arguments: ["casper", "-NSFoo"]), .default)
    }

    func testParseSpaceSeparated() throws {
        XCTAssertEqual(try SessionIdentity.parse(arguments: ["casper", "--session", "dev"]),
                       SessionIdentity(name: "dev"))
    }

    func testParseEqualsForm() throws {
        XCTAssertEqual(try SessionIdentity.parse(arguments: ["casper", "--session=dev"]),
                       SessionIdentity(name: "dev"))
    }

    func testParseMissingValueThrows() {
        XCTAssertThrowsError(try SessionIdentity.parse(arguments: ["casper", "--session"])) {
            XCTAssertEqual($0 as? SessionIdentity.ParseError, .missingValue)
        }
    }

    func testParseInvalidNameThrows() {
        XCTAssertThrowsError(try SessionIdentity.parse(arguments: ["casper", "--session=bad/slash"])) {
            XCTAssertEqual($0 as? SessionIdentity.ParseError, .invalidName("bad/slash"))
        }
        XCTAssertThrowsError(try SessionIdentity.parse(arguments: ["casper", "--session="])) {
            XCTAssertEqual($0 as? SessionIdentity.ParseError, .invalidName(""))
        }
    }
}
