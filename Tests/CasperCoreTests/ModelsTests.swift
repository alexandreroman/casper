import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt", command: nil))
        let browser = Surface(kind: .browser(url: URL(string: "http://localhost:40000")!))
        let layout = LayoutNode.split(
            orientation: .horizontal,
            children: [.leaf(term), .leaf(browser)],
            ratios: [0.6, 0.4]
        )
        // Transient runtime fields (agentState/todos/pendingNotification) are left
        // at their defaults: they are intentionally not persisted, so a non-default
        // value here would never survive the round-trip this fixture feeds.
        let ws = Workspace(
            name: "feat-x",
            worktreePath: "/repo/wt",
            branch: "feat-x",
            portBase: 40010,
            layout: layout
        )
        // `isGitRepo` is not persisted (resolved at runtime), so use `false` here
        // for the round-trip equality to hold; see testIsGitRepoIsNotPersisted.
        let space = Space(
            name: "repo", folderPath: "/repo", isGitRepo: false, workspaces: [ws])
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
        // `isGitRepo` is not persisted (resolved at runtime), so use `false` here
        // for the round-trip equality to hold; see testIsGitRepoIsNotPersisted.
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: false,
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

    func testSplitWithMismatchedRatiosFailsToDecode() {
        // A corrupt `session.json` where `ratios.count != children.count` must be
        // rejected at decode time (routed through SessionStore's self-heal) rather
        // than decoding into a node that later traps in `LayoutTree.closeSurface`.
        let s1 = UUID()
        let s2 = UUID()
        let json = """
        { "split": { "orientation": "horizontal", "children": [
            { "leaf": { "_0": { "id": "\(s1.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } } } },
            { "leaf": { "_0": { "id": "\(s2.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } } } }
        ], "ratios": [1.0] } }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8)))
    }

    func testSplitWithSingleChildFailsToDecode() {
        // A `.split` must hold at least two children; one child is inconsistent.
        let s1 = UUID()
        let json = """
        { "split": { "orientation": "horizontal", "children": [
            { "leaf": { "_0": { "id": "\(s1.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } } } }
        ], "ratios": [1.0] } }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(LayoutNode.self, from: Data(json.utf8)))
    }

    func testWorkspaceKindRawValues() {
        XCTAssertEqual(WorkspaceKind.primary.rawValue, "primary")
        XCTAssertEqual(WorkspaceKind.linked.rawValue, "linked")
    }

    // MARK: - Terminal font-size persistence

    func testSurfaceFontSizeDefaultsToNilAndRoundTrips() throws {
        let withSize = Surface(kind: .terminal(cwd: "/w", command: nil), fontSize: 18.5)
        let data = try JSONEncoder().encode(withSize)
        let decoded = try JSONDecoder().decode(Surface.self, from: data)
        XCTAssertEqual(decoded, withSize)
        XCTAssertEqual(decoded.fontSize, 18.5)

        let withoutSize = Surface(kind: .terminal(cwd: "/w", command: nil))
        XCTAssertNil(withoutSize.fontSize)
    }

    func testSurfaceLegacyDecodeWithoutFontSizeDefaultsToNil() throws {
        // A `session.json` written before font-size persistence existed has no
        // `fontSize` key; decoding must default it to nil (libghostty's own
        // default), matching today's unpersisted behavior.
        let sid = UUID()
        let json = """
        { "id": "\(sid.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } }
        """
        let decoded = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
        XCTAssertNil(decoded.fontSize)
        XCTAssertEqual(decoded.id, sid)
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

    func testInspectorStateLegacyDecodeWithoutWidthDefaultsIt() throws {
        // A `session.json` written before the panel width was persisted has an
        // `inspector` object with no `width` key; decoding must fall back to the
        // default width rather than throw on the missing key.
        let inspector = InspectorState(
            collapsed: false, tab: .browser,
            browser: Surface(kind: .browser(url: URL(string: "http://localhost:5173")!)),
            width: 512)
        let data = try JSONEncoder().encode(inspector)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "width")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(InspectorState.self, from: legacyData)
        XCTAssertEqual(decoded.width, InspectorState.defaultWidth)
        XCTAssertFalse(decoded.collapsed)  // other fields still decode normally
        XCTAssertEqual(decoded.tab, .browser)
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

    // MARK: - Transient runtime fields are not persisted

    func testWorkspaceDoesNotPersistTransientRuntimeFields() throws {
        // agentState / todos / pendingNotification / pendingNotificationMessage
        // are live runtime state, driven by hooks and the CLI. They must never be
        // written to `session.json`, and must reset to their defaults on load.
        let ws = Workspace(
            name: "feat", worktreePath: "/r", branch: "feat",
            agentState: .working,
            todos: [Todo(content: "x", status: .inProgress)],
            pendingNotification: true,
            pendingNotificationMessage: "Task finished",
            portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r", command: nil))))

        let data = try JSONEncoder().encode(ws)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"agentState\""))
        XCTAssertFalse(json.contains("\"todos\""))
        XCTAssertFalse(json.contains("\"pendingNotification\""))
        XCTAssertFalse(json.contains("\"pendingNotificationMessage\""))

        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.agentState, .idle)
        XCTAssertTrue(decoded.todos.isEmpty)
        XCTAssertFalse(decoded.pendingNotification)
        XCTAssertNil(decoded.pendingNotificationMessage)
        // The persisted fields still round-trip.
        XCTAssertEqual(decoded.name, "feat")
        XCTAssertEqual(decoded.portBase, 40000)
    }

    func testWorkspaceLegacyDecodeResetsTransientRuntimeFields() throws {
        // A legacy `session.json` that still carries the three transient keys must
        // ignore them and reset to defaults, not restore the on-disk values.
        let json = """
        { "id": "\(UUID().uuidString)", "name": "legacy", "worktreePath": "/r",
          "branch": "main", "agentState": "working",
          "todos": [ { "content": "x", "status": "in_progress" } ],
          "pendingNotification": true, "portBase": 40000,
          "layout": { "leaf": { "_0": { "id": "\(UUID().uuidString)",
            "kind": { "terminal": { "cwd": "/r", "command": null } } } } },
          "kind": "primary" }
        """
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.agentState, .idle)
        XCTAssertTrue(decoded.todos.isEmpty)
        XCTAssertFalse(decoded.pendingNotification)
        XCTAssertNil(decoded.pendingNotificationMessage)
        XCTAssertEqual(decoded.name, "legacy")  // persisted fields still decode
    }

    // MARK: - Space collapse

    func testSpaceDefaultsToExpanded() {
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true, workspaces: [])
        XCTAssertFalse(space.isCollapsed)
    }

    func testSpaceCodableRoundTripWhenCollapsed() throws {
        // `isGitRepo` is not persisted (resolved at runtime), so use `false` here
        // for the round-trip equality to hold; see testIsGitRepoIsNotPersisted.
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: false,
            isCollapsed: true, workspaces: [])
        let data = try JSONEncoder().encode(space)
        let decoded = try JSONDecoder().decode(Space.self, from: data)
        XCTAssertEqual(decoded, space)
        XCTAssertTrue(decoded.isCollapsed)
    }

    func testSpaceLegacyDecodeWithoutIsCollapsedDefaultsToFalse() throws {
        // A `session.json` written before the collapse flag existed has a `space`
        // object with no `isCollapsed` key; decoding must fall back to expanded
        // rather than throw on the missing key.
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true,
            isCollapsed: true, workspaces: [])
        let data = try JSONEncoder().encode(space)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "isCollapsed")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Space.self, from: legacyData)
        XCTAssertFalse(decoded.isCollapsed)
        XCTAssertEqual(decoded.name, "app")  // other fields still decode normally
    }

    // MARK: - Selected workspace persistence

    func testSessionLegacyDecodeWithoutSelectedWorkspaceIDDefaultsToNil() throws {
        // A `session.json` written before the selected workspace was persisted has
        // no `selectedWorkspaceID` key; decoding must fall back to nil rather than
        // throw on the missing key.
        let session = Session(spaces: [
            Space(name: "app", folderPath: "/r", isGitRepo: true, workspaces: []),
        ], selectedWorkspaceID: UUID())
        let data = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "selectedWorkspaceID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Session.self, from: legacyData)
        XCTAssertNil(decoded.selectedWorkspaceID)
        XCTAssertEqual(decoded.spaces.first?.name, "app")  // other fields decode normally
    }

    func testSessionCodableRoundTripWithSelectedWorkspaceID() throws {
        let selected = UUID()
        // `isGitRepo` is not persisted (resolved at runtime), so use `false` here
        // for the round-trip equality to hold; see testIsGitRepoIsNotPersisted.
        let session = Session(spaces: [
            Space(name: "app", folderPath: "/r", isGitRepo: false, workspaces: []),
        ], selectedWorkspaceID: selected)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.selectedWorkspaceID, selected)
    }

    // MARK: - isGitRepo is runtime-only

    func testIsGitRepoIsNotPersisted() throws {
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true, workspaces: [])
        let data = try JSONEncoder().encode(space)

        // The flag is dropped from the encoded form entirely.
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["isGitRepo"])

        // Decoding always yields a non-Git Space; it is resolved at runtime.
        let decoded = try JSONDecoder().decode(Space.self, from: data)
        XCTAssertFalse(decoded.isGitRepo)
        XCTAssertEqual(decoded.name, "app")          // persisted fields still decode
        XCTAssertEqual(decoded.folderPath, "/r")
    }
}
