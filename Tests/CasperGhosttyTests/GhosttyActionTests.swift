import GhosttyKit
import XCTest
@testable import CasperGhostty

final class GhosttyActionTests: XCTestCase {
    func testDecodesSetTitle() {
        "Casper".withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = cstr
            XCTAssertEqual(GhosttyAction.decode(action), .setTitle("Casper"))
        }
    }

    func testDecodesSetTitleWithNilPointerAsEmptyString() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_TITLE
        XCTAssertEqual(GhosttyAction.decode(action), .setTitle(""))
    }

    func testDecodesSetTabTitle() {
        "worktree-a".withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TAB_TITLE
            action.action.set_tab_title.title = cstr
            XCTAssertEqual(GhosttyAction.decode(action), .setTabTitle("worktree-a"))
        }
    }

    func testDecodesPwd() {
        "/tmp/wt".withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_PWD
            action.action.pwd.pwd = cstr
            XCTAssertEqual(GhosttyAction.decode(action), .pwd("/tmp/wt"))
        }
    }

    func testDecodesRingBell() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL
        XCTAssertEqual(GhosttyAction.decode(action), .ringBell)
    }

    func testDecodesRender() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER
        XCTAssertEqual(GhosttyAction.decode(action), .render)
    }

    func testDecodesChildExited() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SHOW_CHILD_EXITED
        action.action.child_exited.exit_code = 42
        XCTAssertEqual(GhosttyAction.decode(action), .childExited(exitCode: 42))
    }

    func testDecodesDesktopNotification() {
        "Build finished".withCString { titleCStr in
            "casper build succeeded".withCString { bodyCStr in
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
                action.action.desktop_notification.title = titleCStr
                action.action.desktop_notification.body = bodyCStr
                XCTAssertEqual(
                    GhosttyAction.decode(action),
                    .desktopNotification(title: "Build finished", body: "casper build succeeded"))
            }
        }
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

    func testUnmodeledTagBecomesOther() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_EQUALIZE_SPLITS
        XCTAssertEqual(
            GhosttyAction.decode(action),
            .other(tag: GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue))
    }
}
