import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt", command: nil))
        let browser = Surface(kind: .browser(url: URL(string: "http://localhost:40000")!))
        let diff = Surface(kind: .diff(againstHead: true))
        let layout = LayoutNode.split(
            orientation: .horizontal,
            children: [.leaf(term), .leaf(browser), .leaf(diff)],
            ratios: [0.4, 0.3, 0.3]
        )
        let ws = Workspace(
            name: "feat-x",
            worktreePath: "/repo/wt",
            branch: "feat-x",
            agentState: .running,
            todos: [Todo(content: "wire up", status: .inProgress)],
            pendingNotification: false,
            portBase: 40010,
            layout: layout
        )
        let space = Space(
            name: "repo", folderPath: "/repo", isGitRepo: true, workspaces: [ws])
        return Session(spaces: [space])
    }

    func testSessionCodableRoundTrip() throws {
        let original = sampleSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTodoStatusRawValuesMatchClaudeCode() {
        XCTAssertEqual(TodoStatus.pending.rawValue, "pending")
        XCTAssertEqual(TodoStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TodoStatus.completed.rawValue, "completed")
    }

    func testSpaceSessionRoundTrip() throws {
        let primary = Workspace(
            name: "app", worktreePath: "/r", branch: "main",
            portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r", command: nil))),
            kind: .primary)
        let linked = Workspace(
            name: "feat", worktreePath: "/r/.casper/worktrees/feat", branch: "feat",
            portBase: 40010,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r/.casper/worktrees/feat", command: nil))),
            kind: .linked, baseBranch: "main")
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true,
            workspaces: [primary, linked])
        let session = Session(spaces: [space])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.spaces.first?.workspaces.first?.kind, .primary)
        XCTAssertEqual(decoded.spaces.first?.workspaces.last?.baseBranch, "main")
    }

    func testLegacyTabGroupDecodesIntoSplitOfLeaves() throws {
        // A previously persisted `tabGroup` with 2 surfaces must migrate into an
        // even horizontal split of one leaf per surface.
        let s1 = UUID()
        let s2 = UUID()
        let json = """
        { "tabGroup": { "surfaces": [
            { "id": "\(s1.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } },
            { "id": "\(s2.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } }
        ], "activeIndex": 0 } }
        """
        let node = try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8))
        guard case .split(let orientation, let children, let ratios) = node else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(orientation, .horizontal)
        XCTAssertEqual(ratios, [0.5, 0.5])
        guard case .leaf(let l1) = children[0], case .leaf(let l2) = children[1] else {
            return XCTFail("expected two leaves")
        }
        XCTAssertEqual([l1.id, l2.id], [s1, s2])
    }

    func testLegacySingleSurfaceTabGroupDecodesIntoLeaf() throws {
        let sid = UUID()
        let json = """
        { "tabGroup": { "surfaces": [
            { "id": "\(sid.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } }
        ], "activeIndex": 0 } }
        """
        let node = try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8))
        guard case .leaf(let surface) = node else { return XCTFail("expected a leaf") }
        XCTAssertEqual(surface.id, sid)
    }

    func testWorkspaceKindRawValues() {
        XCTAssertEqual(WorkspaceKind.primary.rawValue, "primary")
        XCTAssertEqual(WorkspaceKind.linked.rawValue, "linked")
    }

    // MARK: - Inspector state (Right Inspector Panel)

    func testInspectorStateDefaults() {
        let state = InspectorState()
        XCTAssertTrue(state.collapsed)
        XCTAssertEqual(state.tab, .diff)
        guard case .browser(let url) = state.browser.kind else {
            return XCTFail("default inspector browser must be a browser surface")
        }
        XCTAssertEqual(url.absoluteString, "about:blank")
    }

    func testWorkspaceCodableRoundTripWithNonDefaultInspector() throws {
        let inspector = InspectorState(
            collapsed: false, tab: .browser,
            browser: Surface(kind: .browser(url: URL(string: "http://localhost:5173")!)))
        let ws = Workspace(
            name: "feat", worktreePath: "/r", branch: "feat", portBase: 40010,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r", command: nil))),
            inspector: inspector)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
    }

    func testWorkspaceLegacyDecodeWithoutInspectorDefaultsIt() throws {
        // A `session.json` written before the inspector existed has no `inspector`
        // key; decoding it must fall back to a default (collapsed) InspectorState.
        let ws = Workspace(
            name: "legacy", worktreePath: "/r", branch: "main", portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r", command: nil))),
            inspector: InspectorState(collapsed: false, tab: .browser))
        let data = try JSONEncoder().encode(ws)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "inspector")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Workspace.self, from: legacyData)
        // A fresh InspectorState mints a random browser Surface.id, so the two
        // are never Equatable-equal; assert the default's meaningful fields.
        let expected = InspectorState()
        XCTAssertEqual(decoded.inspector.collapsed, expected.collapsed)
        XCTAssertEqual(decoded.inspector.tab, expected.tab)
        XCTAssertEqual(decoded.inspector.browser.kind, expected.browser.kind)
    }
}
