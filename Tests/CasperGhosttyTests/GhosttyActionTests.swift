import GhosttyKit
import XCTest
@testable import CasperGhostty

final class GhosttyActionTests: XCTestCase {
    func testDecodesRender() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER
        XCTAssertEqual(GhosttyAction.decode(action), .render)
    }

    func testDecodesOpenURL() {
        let urlString = "https://example.com"
        urlString.withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            action.action.open_url.url = cstr
            action.action.open_url.len = UInt(urlString.utf8.count)
            XCTAssertEqual(GhosttyAction.decode(action), .openURL("https://example.com"))
        }
    }

    func testDecodesOpenURLWithNilPointerAsEmptyString() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        XCTAssertEqual(GhosttyAction.decode(action), .openURL(""))
    }

    func testDecodesNewSplitRight() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_SPLIT
        action.action.new_split = GHOSTTY_SPLIT_DIRECTION_RIGHT
        XCTAssertEqual(GhosttyAction.decode(action), .newSplit(.right))
    }

    func testDecodesNewSplitDown() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_SPLIT
        action.action.new_split = GHOSTTY_SPLIT_DIRECTION_DOWN
        XCTAssertEqual(GhosttyAction.decode(action), .newSplit(.down))
    }

    func testDecodesNewSplitLeft() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_SPLIT
        action.action.new_split = GHOSTTY_SPLIT_DIRECTION_LEFT
        XCTAssertEqual(GhosttyAction.decode(action), .newSplit(.left))
    }

    func testDecodesNewSplitUp() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_SPLIT
        action.action.new_split = GHOSTTY_SPLIT_DIRECTION_UP
        XCTAssertEqual(GhosttyAction.decode(action), .newSplit(.up))
    }

    func testDecodesNewTab() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_TAB
        XCTAssertEqual(GhosttyAction.decode(action), .newTab)
    }

    func testDecodesNewWindow() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_WINDOW
        XCTAssertEqual(GhosttyAction.decode(action), .newWindow)
    }

    func testDecodesCloseTab() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_TAB
        XCTAssertEqual(GhosttyAction.decode(action), .closeTab)
    }

    func testDecodesCloseWindow() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_WINDOW
        XCTAssertEqual(GhosttyAction.decode(action), .closeWindow)
    }

    func testDecodesQuit() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_QUIT
        XCTAssertEqual(GhosttyAction.decode(action), .quit)
    }

    func testUnmodeledTagBecomesOther() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_EQUALIZE_SPLITS
        XCTAssertEqual(
            GhosttyAction.decode(action),
            .other(tag: GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue))
    }
}
