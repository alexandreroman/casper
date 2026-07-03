import XCTest
import CasperCore
@testable import CasperUI

final class WorkspacePresentationTests: XCTestCase {
    func testBadgeGlyphForEachState() {
        XCTAssertEqual(AgentState.running.badgeGlyph, "●")
        XCTAssertEqual(AgentState.waiting.badgeGlyph, "◐")
        XCTAssertEqual(AgentState.done.badgeGlyph, "✓")
        XCTAssertEqual(AgentState.error.badgeGlyph, "✕")
        XCTAssertEqual(AgentState.idle.badgeGlyph, "○")
        XCTAssertEqual(AgentState.unknown.badgeGlyph, "○")
    }

    func testProgressLabel() {
        let none = Workspace(name: "a", worktreePath: "/a", branch: "",
                             portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0))
        XCTAssertNil(none.progressLabel)

        var some = none
        some.todos = [
            Todo(content: "x", status: .completed),
            Todo(content: "y", status: .inProgress),
            Todo(content: "z", status: .pending),
        ]
        XCTAssertEqual(some.progressLabel, "1/3")
    }
}
