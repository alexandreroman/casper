import XCTest
import CasperGit
@testable import CasperUI

final class DiffFileMatchTests: XCTestCase {
    /// A modified file whose `id` is `newPath` (== `oldPath`).
    private func file(_ path: String) -> GitDiffFile {
        GitDiffFile(oldPath: path, newPath: path, status: .modified, isBinary: false, hunks: [])
    }

    func testExactPathMatch() {
        let files = [file("Sources/App/Foo.swift"), file("Sources/App/Bar.swift")]
        XCTAssertEqual(DiffFileMatch.match("Sources/App/Foo.swift", in: files), "Sources/App/Foo.swift")
    }

    func testSuffixFragmentMatch() {
        let files = [file("Sources/App/Foo.swift"), file("Sources/App/Bar.swift")]
        XCTAssertEqual(DiffFileMatch.match("App/Foo.swift", in: files), "Sources/App/Foo.swift")
    }

    func testBasenameMatch() {
        let files = [file("Sources/App/Foo.swift"), file("Sources/App/Bar.swift")]
        XCTAssertEqual(DiffFileMatch.match("Foo.swift", in: files), "Sources/App/Foo.swift")
    }

    func testNoMatchReturnsNil() {
        let files = [file("Sources/App/Foo.swift"), file("Sources/App/Bar.swift")]
        XCTAssertNil(DiffFileMatch.match("Missing.swift", in: files))
    }
}
