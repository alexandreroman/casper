import XCTest
@testable import CasperCore

final class GitInfoExcludeTests: XCTestCase {
    func testAddsWhenAbsent() {
        let out = GitInfoExclude.ensuring(GitInfoExclude.casperEntry, in: "# stuff\n")
        XCTAssertEqual(out, "# stuff\n.casper/\n")
    }
    func testNilWhenPresent() {
        XCTAssertNil(GitInfoExclude.ensuring(
            GitInfoExclude.casperEntry, in: "a\n.casper/\nb\n"))
    }
    func testAddsNewlineWhenMissing() {
        XCTAssertEqual(
            GitInfoExclude.ensuring(GitInfoExclude.casperEntry, in: "x"),
            "x\n.casper/\n")
    }
    func testFromEmptyOrNil() {
        XCTAssertEqual(GitInfoExclude.ensuring(GitInfoExclude.casperEntry, in: nil),
                       ".casper/\n")
    }
}
