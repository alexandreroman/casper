import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt"))
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

    func testDraggedRatiosSurviveSessionRoundTrip() throws {
        // A nested split so we exercise addressing a non-root split by path.
        let a = Surface(kind: .terminal(cwd: "/w"))
        let b = Surface(kind: .terminal(cwd: "/w"))
        let c = Surface(kind: .terminal(cwd: "/w"))
        let nested = LayoutNode.split(
            orientation: .vertical, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])
        let root = LayoutNode.split(
            orientation: .horizontal, children: [.leaf(a), nested], ratios: [0.5, 0.5])
        // Simulate two divider drags: the root and the nested split.
        var layout = LayoutTree.updateRatios(in: root, at: [], ratios: [0.35, 0.65])
        layout = LayoutTree.updateRatios(in: layout, at: [1], ratios: [0.2, 0.8])

        let ws = Workspace(
            name: "feat-x", worktreePath: "/repo/wt", branch: "feat-x",
            portBase: 40010, layout: layout)
        let space = Space(
            name: "repo", folderPath: "/repo", isGitRepo: false, workspaces: [ws])
        let session = Session(spaces: [space])

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        let decodedLayout = decoded.spaces.first?.workspaces.first?.layout
        guard case .split(_, let children, let rootRatios)? = decodedLayout else { return XCTFail() }
        XCTAssertEqual(rootRatios, [0.35, 0.65])
        guard case .split(_, _, let nestedRatios) = children[1] else { return XCTFail() }
        XCTAssertEqual(nestedRatios, [0.2, 0.8])
    }

    func testTodoStatusRawValuesMatchClaudeCode() {
        XCTAssertEqual(TodoStatus.pending.rawValue, "pending")
        XCTAssertEqual(TodoStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TodoStatus.completed.rawValue, "completed")
    }

    func testFirstOrderedWorkspaceIDAgreesWithOrderedWorkspaces() {
        func workspace(_ name: String, kind: WorkspaceKind) -> Workspace {
            Workspace(
                name: name, worktreePath: "/r/\(name)", branch: name,
                portBase: 40000,
                layout: .leaf(Surface(kind: .terminal(cwd: "/r/\(name)"))),
                kind: kind)
        }
        // Deliberately out of display order: a linked workspace sorting before the
        // primary by name, so a comparator that ignored `kind` would disagree.
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true,
            workspaces: [
                workspace("beta", kind: .linked),
                workspace("main", kind: .primary),
                workspace("alpha", kind: .linked),
            ])
        XCTAssertEqual(space.firstOrderedWorkspaceID, space.orderedWorkspaces.first?.id)
        XCTAssertEqual(space.orderedWorkspaces.first?.name, "main")

        let empty = Space(name: "e", folderPath: "/e", isGitRepo: false, workspaces: [])
        XCTAssertNil(empty.firstOrderedWorkspaceID)
        XCTAssertEqual(empty.firstOrderedWorkspaceID, empty.orderedWorkspaces.first?.id)
    }

    func testSpaceSessionRoundTrip() throws {
        let primary = Workspace(
            name: "app", worktreePath: "/r", branch: "main",
            portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
            kind: .primary)
        let linked = Workspace(
            name: "feat", worktreePath: "/r/.casper/worktrees/feat", branch: "feat",
            portBase: 40010,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r/.casper/worktrees/feat"))),
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
        let withSize = Surface(kind: .terminal(cwd: "/w"), fontSize: 18.5)
        let data = try JSONEncoder().encode(withSize)
        let decoded = try JSONDecoder().decode(Surface.self, from: data)
        XCTAssertEqual(decoded, withSize)
        XCTAssertEqual(decoded.fontSize, 18.5)

        let withoutSize = Surface(kind: .terminal(cwd: "/w"))
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
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
            inspector: inspector)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
    }

    func testWorkspaceCodableRoundTripWithLastUsedEditor() throws {
        let ws = Workspace(
            name: "feat", worktreePath: "/r", branch: "feat", portBase: 40011,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
            lastUsedEditor: .intellijIdea)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
        XCTAssertEqual(decoded.lastUsedEditor, .intellijIdea)
    }

    func testWorkspaceLegacyDecodeWithoutLastUsedEditorDefaultsToNil() throws {
        // A `session.json` written before this field existed has no
        // `lastUsedEditor` key; decoding it must default to nil, not throw.
        let ws = Workspace(
            name: "legacy", worktreePath: "/r", branch: "main", portBase: 40001,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))))
        let data = try JSONEncoder().encode(ws)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "lastUsedEditor")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Workspace.self, from: legacyData)
        XCTAssertNil(decoded.lastUsedEditor)
    }

    func testWorkspaceRoundTripsLastUsedScript() throws {
        var ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        ws.lastUsedScript = "test"
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.lastUsedScript, "test")
    }

    func testWorkspaceLastUsedScriptDefaultsNil() throws {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        XCTAssertNil(ws.lastUsedScript)
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
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
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

    // MARK: - EditorKind

    func testEditorKindPriorityOrderIsVSCodeThenIntelliJThenXcode() {
        XCTAssertEqual(EditorKind.priorityOrder, [.vscode, .intellijIdea, .xcode])
    }

    func testEditorKindMetadataIsDistinctPerCase() {
        for kind in EditorKind.allCases {
            XCTAssertFalse(kind.cliCommand.isEmpty)
            XCTAssertFalse(kind.bundleIdentifiers.isEmpty)
            XCTAssertFalse(kind.displayName.isEmpty)
        }
        XCTAssertEqual(EditorKind.vscode.cliCommand, "code")
        XCTAssertEqual(EditorKind.intellijIdea.cliCommand, "idea")
        XCTAssertEqual(EditorKind.xcode.cliCommand, "xed")
        XCTAssertEqual(EditorKind.intellijIdea.bundleIdentifiers,
                       ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"])
    }

    func testEditorKindCodableRoundTrip() throws {
        for kind in EditorKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(EditorKind.self, from: data), kind)
        }
    }

    // MARK: - Transient runtime fields are not persisted

    func testWorkspaceDoesNotPersistTransientRuntimeFields() throws {
        // agentState / todos / pendingNotification / pendingNotificationMessage /
        // infoMarkdown / infoUnread are live runtime state, driven by hooks, the
        // CLI, and `casper info set`/`clear`. They must never be written to
        // `session.json`, and must reset to their defaults on load.
        let ws = Workspace(
            name: "feat", worktreePath: "/r", branch: "feat",
            agentState: .working,
            todos: [Todo(content: "x", status: .inProgress)],
            pendingNotification: true,
            pendingNotificationMessage: "Done",
            portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
            infoMarkdown: "## Ready", infoUnread: true)

        let data = try JSONEncoder().encode(ws)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"agentState\""))
        XCTAssertFalse(json.contains("\"todos\""))
        XCTAssertFalse(json.contains("\"pendingNotification\""))
        XCTAssertFalse(json.contains("\"pendingNotificationMessage\""))
        XCTAssertFalse(json.contains("\"infoMarkdown\""))
        XCTAssertFalse(json.contains("\"infoUnread\""))

        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.agentState, .idle)
        XCTAssertTrue(decoded.todos.isEmpty)
        XCTAssertFalse(decoded.pendingNotification)
        XCTAssertNil(decoded.pendingNotificationMessage)
        XCTAssertNil(decoded.infoMarkdown)
        XCTAssertFalse(decoded.infoUnread)
        // The persisted fields still round-trip.
        XCTAssertEqual(decoded.name, "feat")
        XCTAssertEqual(decoded.portBase, 40000)
    }

    func testWorkspaceLegacyDecodeResetsTransientRuntimeFields() throws {
        // A legacy `session.json` that still carries the transient keys — whether
        // written by an older build that persisted them, or hand-edited — must
        // ignore them and reset to defaults, not restore the on-disk values.
        let json = """
        { "id": "\(UUID().uuidString)", "name": "legacy", "worktreePath": "/r",
          "branch": "main", "agentState": "working",
          "todos": [ { "content": "x", "status": "in_progress" } ],
          "pendingNotification": true, "portBase": 40000,
          "layout": { "leaf": { "_0": { "id": "\(UUID().uuidString)",
            "kind": { "terminal": { "cwd": "/r", "command": null } } } } },
          "kind": "primary", "infoMarkdown": "## Stale", "infoUnread": true }
        """
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.agentState, .idle)
        XCTAssertTrue(decoded.todos.isEmpty)
        XCTAssertFalse(decoded.pendingNotification)
        XCTAssertNil(decoded.pendingNotificationMessage)
        XCTAssertNil(decoded.infoMarkdown)
        XCTAssertFalse(decoded.infoUnread)
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

    // MARK: - Dismissed agent reminders

    func testSessionRoundTripPreservesDismissedAgentReminders() throws {
        let session = Session(
            spaces: [Space(name: "app", folderPath: "/r", isGitRepo: false, workspaces: [])],
            dismissedAgentReminders: [CodingAgent.claudeCode.reminderID, CodingAgent.opencode.reminderID])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(
            decoded.dismissedAgentReminders,
            [CodingAgent.claudeCode.reminderID, CodingAgent.opencode.reminderID])
    }

    func testSessionDefaultsToNoDismissedAgentReminders() {
        XCTAssertTrue(Session().dismissedAgentReminders.isEmpty)
    }

    func testSessionLegacyDecodeWithoutDismissedAgentRemindersDefaultsToEmpty() throws {
        // A `session.json` written before the reminders existed has no
        // `dismissedAgentReminders` key; decoding must yield an empty set rather
        // than throw on the missing key.
        let json = """
        { "spaces": [ { "id": "\(UUID().uuidString)", "name": "app",
            "folderPath": "/r", "isCollapsed": false, "workspaces": [] } ] }
        """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.dismissedAgentReminders.isEmpty)
        XCTAssertEqual(decoded.spaces.first?.name, "app")  // other fields decode normally
    }

    func testSessionLegacyDecodeWithoutLastNewSpaceLocationDecodesToNil() throws {
        // A `session.json` written before the creation panel existed has no
        // `lastNewSpaceLocation` key; decoding must yield nil rather than throw on
        // the missing key.
        let json = """
        { "spaces": [ { "id": "\(UUID().uuidString)", "name": "app",
            "folderPath": "/r", "isCollapsed": false, "workspaces": [] } ] }
        """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(decoded.lastNewSpaceLocation)
        XCTAssertEqual(decoded.spaces.first?.name, "app")  // other fields decode normally
    }

    func testLastNewSpaceLocationIsOmittedWhenNil() throws {
        // `encodeIfPresent`, not `encode`: no remembered location must leave the key
        // out rather than write `null`. Pinned because both coders are hand-rolled and
        // "simplifying" this to `encode` would change the on-disk shape.
        let data = try JSONEncoder().encode(Session())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["lastNewSpaceLocation"])
        XCTAssertNotNil(object["spaces"])
    }

    func testSelectedWorkspaceIDIsOmittedWhenNil() throws {
        // `encodeIfPresent`, not `encode`: a nil selection must leave the key out
        // rather than write `null`. Pinned because both coders are hand-rolled and
        // "simplifying" this to `encode` would change the on-disk shape.
        let data = try JSONEncoder().encode(Session())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["selectedWorkspaceID"])
        XCTAssertNotNil(object["spaces"])
    }

    func testExplicitNullSelectedWorkspaceIDDecodesToNil() throws {
        let json = #"{"spaces": [], "selectedWorkspaceID": null}"#
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(decoded.selectedWorkspaceID)
    }

    func testLegacySelectedWorkspaceIDRoundTrips() throws {
        // A `session.json` written before the reminders existed still carries a
        // real selection, which must survive the hand-rolled decode untouched.
        let workspaceID = UUID()
        let json = """
            { "spaces": [], "selectedWorkspaceID": "\(workspaceID.uuidString)" }
            """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.selectedWorkspaceID, workspaceID)

        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertEqual(object["selectedWorkspaceID"] as? String, workspaceID.uuidString)
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: reencoded), decoded)
    }

    func testDismissedAgentRemindersEncodeAsASortedArray() throws {
        // A `Set` encodes as an unordered JSON array whose order varies with the
        // per-process hash seed, so the persisted bytes would otherwise shift
        // between saves for an unchanged session. More ids than the three real
        // agents, so an unsorted implementation cannot pass by landing in sorted
        // order by chance.
        let ids = CodingAgent.allCases.map(\.reminderID) + ["zeta", "aider", "mango"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // matches SessionStore's encoder

        let encoded = try encoder.encode(Session(dismissedAgentReminders: Set(ids)))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["dismissedAgentReminders"] as? [String], ids.sorted())

        // Two equal sets built from different insertion orders must encode identically.
        let reversed = try encoder.encode(Session(dismissedAgentReminders: Set(ids.reversed())))
        XCTAssertEqual(encoded, reversed)
    }
}
