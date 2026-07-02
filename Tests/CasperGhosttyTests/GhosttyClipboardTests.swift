import GhosttyKit
import XCTest
@testable import CasperGhostty

final class GhosttyClipboardTests: XCTestCase {
    func testReadsDataFromFirstContent() {
        "hello".withCString { data in
            "text/plain".withCString { mime in
                var content = ghostty_clipboard_content_s(mime: mime, data: data)
                withUnsafePointer(to: &content) { ptr in
                    XCTAssertEqual(clipboardString(from: ptr, count: 1), "hello")
                }
            }
        }
    }

    func testNilContentIsNil() {
        XCTAssertNil(clipboardString(from: nil, count: 0))
    }
}
