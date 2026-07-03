import XCTest
import CasperCore
import CasperGhostty
@testable import CasperUI

@MainActor
final class LayoutActionHandlerTests: XCTestCase {
    func testHandlerForwardsLayoutActionsAndClaimsThem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-lah-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(fileURL: dir.appendingPathComponent("s.json"))
        let model = AppModel(sessionStore: store)
        model.addSpace(folderURL: dir, probe: { _ in nil })  // non-Git degenerate Space
        model.focusSurface(LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0])

        let handler = LayoutActionHandler(model: model)
        XCTAssertTrue(handler.handle(.newSplit(.right)))   // claimed
        XCTAssertEqual(
            LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 2)
        XCTAssertFalse(handler.handle(.ringBell))          // not a layout action
    }
}
