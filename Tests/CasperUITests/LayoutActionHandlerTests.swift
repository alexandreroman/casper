import XCTest
import CasperCore
import CasperGhostty
@testable import CasperUI

@MainActor
final class LayoutActionHandlerTests: XCTestCase {
    func testHandlerForwardsLayoutActionsAndClaimsThem() throws {
        let dir = makeTemporaryDirectory(prefix: "casper-lah")
        let model = makeModel()
        model.addSpace(folderURL: dir, probe: { _ in nil })  // non-Git degenerate Space
        model.focusSurface(LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0])

        let handler = LayoutActionHandler(model: model)
        XCTAssertTrue(handler.handle(.newSplit(.right)))   // claimed
        XCTAssertEqual(
            LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 2)
        XCTAssertFalse(handler.handle(.render))            // not a layout action
    }

    /// ⌘N is a libghostty keybind, so `.newWindow` is the only thing the keystroke can
    /// arrive as — `GhosttyCommandNRoutingTests` pins that half. This is the other
    /// half: the action has to reach "New Space…", or the shortcut is claimed from the
    /// main menu and then does nothing at all.
    ///
    /// The panel itself is substituted, the way `GhosttyClipboardRead.approveUntrusted`
    /// is: an `NSSavePanel` cannot run under XCTest. Cancelling is what the stand-in
    /// reports, so nothing is created and nothing is written.
    func testNewWindowOpensTheNewSpacePanelExactlyOnceAndClaimsTheAction() {
        let model = makeModel()
        var presentations = 0
        let presented = expectation(description: "the new-Space location panel is asked for")
        let original = AppModel.chooseNewSpaceLocation
        defer { AppModel.chooseNewSpaceLocation = original }
        AppModel.chooseNewSpaceLocation = { _ in
            presentations += 1
            presented.fulfill()
            return nil  // the user cancels
        }

        let handler = LayoutActionHandler(model: model)
        XCTAssertTrue(
            handler.handle(.newWindow),
            "an unclaimed .newWindow takes ⌘N away from the menu item without replacing it")

        // The presentation is deliberately deferred off libghostty's key-processing
        // tick, so it lands on a later turn of the main run loop rather than inline.
        wait(for: [presented], timeout: 2)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(model.spaces.isEmpty)
    }
}
