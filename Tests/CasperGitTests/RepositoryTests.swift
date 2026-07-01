import XCTest
import Clibgit2

final class Clibgit2SmokeTests: XCTestCase {
    func testLibgit2VersionIsLinked() {
        var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        XCTAssertEqual(major, 1)
        XCTAssertGreaterThanOrEqual(minor, 9)
    }
}
