import XCTest
@testable import CasperCLI

final class LaunchModeTests: XCTestCase {
    func testNoArgumentsMeansGUI() {
        XCTAssertEqual(LaunchMode.detect(arguments: ["/path/to/casper"]), .gui)
    }

    func testEmptyArgumentsMeansGUI() {
        XCTAssertEqual(LaunchMode.detect(arguments: []), .gui)
    }

    func testASubcommandMeansCLI() {
        XCTAssertEqual(
            LaunchMode.detect(arguments: ["/path/to/casper", "hooks"]), .cli)
    }
}
