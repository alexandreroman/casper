import CasperGit
import XCTest
@testable import CasperUI

final class DiffLineStyleTests: XCTestCase {
    func testPrefix() {
        XCTAssertEqual(DiffLineStyle.prefix(for: .addition), "+")
        XCTAssertEqual(DiffLineStyle.prefix(for: .deletion), "-")
        XCTAssertEqual(DiffLineStyle.prefix(for: .context), " ")
    }
}
