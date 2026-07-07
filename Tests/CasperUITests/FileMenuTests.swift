import AppKit
import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class FileMenuTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return SessionStore(fileURL: url)
    }

    func testFileMenuItemBuildsOnlyAddFolder() {
        let model = AppModel(sessionStore: makeStore())
        let item = model.fileMenuItem()
        let titles = item.submenu?.items.map(\.title)
        XCTAssertEqual(titles, ["Add folder…"])
    }
}
