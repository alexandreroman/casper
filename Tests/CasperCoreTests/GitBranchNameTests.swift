import XCTest
@testable import CasperCore

final class GitBranchNameTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(GitBranchName.sanitize("My Feature"), "my-feature")
        XCTAssertEqual(GitBranchName.sanitize("feat/AB C"), "feat/ab-c")
        XCTAssertEqual(GitBranchName.sanitize("a~b:c?d*e"), "a-b-c-d-e")
        XCTAssertEqual(GitBranchName.sanitize("  --hello--  "), "hello")
        XCTAssertNil(GitBranchName.sanitize(""))
        XCTAssertNil(GitBranchName.sanitize("   "))
        XCTAssertNil(GitBranchName.sanitize("@"))
    }
}
