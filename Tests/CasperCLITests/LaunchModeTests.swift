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

    func testHelpAndVersionFlagsMeanCLI() {
        XCTAssertEqual(LaunchMode.detect(arguments: ["casper", "--help"]), .cli)
        XCTAssertEqual(LaunchMode.detect(arguments: ["casper", "-h"]), .cli)
        XCTAssertEqual(LaunchMode.detect(arguments: ["casper", "--version"]), .cli)
    }

    func testInjectedSystemLaunchFlagsMeanGUI() {
        XCTAssertEqual(
            LaunchMode.detect(arguments: ["casper", "-NSDocumentRevisionsDebugMode", "YES"]), .gui)
        XCTAssertEqual(
            LaunchMode.detect(arguments: ["casper", "-psn_0_12345"]), .gui)
        XCTAssertEqual(
            LaunchMode.detect(arguments: ["casper", "-AppleLanguages", "(en)"]), .gui)
    }
}
