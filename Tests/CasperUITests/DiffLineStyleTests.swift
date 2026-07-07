import CasperGit
import SwiftUI
import XCTest
@testable import CasperUI

final class DiffLineStyleTests: XCTestCase {
    func testPrefix() {
        XCTAssertEqual(DiffLineStyle.prefix(for: .addition), "+")
        XCTAssertEqual(DiffLineStyle.prefix(for: .deletion), "-")
        XCTAssertEqual(DiffLineStyle.prefix(for: .context), " ")
    }

    func testTintsMatchClaudeCodeReference() {
        XCTAssertEqual(DiffLineStyle.insertionTint, Color(red: 0.529, green: 0.757, blue: 0.388))
        XCTAssertEqual(DiffLineStyle.deletionTint, Color(red: 0.725, green: 0.416, blue: 0.369))
    }

    func testBackgroundIsASolidSaturatedColor() {
        XCTAssertEqual(DiffLineStyle.background(for: .addition), Color(red: 0.082, green: 0.149, blue: 0.024))
        XCTAssertEqual(DiffLineStyle.background(for: .deletion), Color(red: 0.188, green: 0.043, blue: 0.012))
        XCTAssertEqual(DiffLineStyle.background(for: .context), Color.clear)
    }

    func testLineNumberPicksOldForDeletionAndNewForAdditionOrContext() {
        let deletion = GitDiffLine(kind: .deletion, content: "x", oldLineNumber: 30, newLineNumber: nil)
        let addition = GitDiffLine(kind: .addition, content: "x", oldLineNumber: nil, newLineNumber: 31)
        let context = GitDiffLine(kind: .context, content: "x", oldLineNumber: 5, newLineNumber: 5)

        XCTAssertEqual(DiffLineStyle.lineNumber(for: deletion), 30)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: addition), 31)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: context), 5)
    }
}
