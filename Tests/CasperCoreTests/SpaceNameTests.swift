import XCTest
@testable import CasperCore

final class SpaceNameTests: XCTestCase {
    func testHTTPS() {
        XCTAssertEqual(
            SpaceName.derive(remoteURL: "https://github.com/acme/casper.git",
                             folderName: "x"), "casper")
    }
    func testSSH() {
        XCTAssertEqual(
            SpaceName.derive(remoteURL: "git@github.com:acme/casper.git",
                             folderName: "x"), "casper")
    }
    func testNoRemoteFallsBack() {
        XCTAssertEqual(SpaceName.derive(remoteURL: nil, folderName: "myfolder"),
                       "myfolder")
    }
}
