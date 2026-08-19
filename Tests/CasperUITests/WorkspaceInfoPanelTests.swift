import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Layout smoke tests: the panel is a pure function of its Markdown, so what is
/// worth locking in is that it composes and stays inside its declared width
/// whatever the message throws at it. Pixels still need human eyes.
@MainActor
final class WorkspaceInfoPanelTests: XCTestCase {
    /// A model seeded with one Git-less space + workspace, mirroring
    /// `ControlHandlerTests.seededModel()`.
    private static func seeded() -> (AppModel, Workspace) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws)
    }

    /// `NSHostingView.fittingSize` reflects the SwiftUI layout tree as of the
    /// last layout pass, so `layoutSubtreeIfNeeded()` before reading it is
    /// required — not optional the way it looked in the sibling
    /// `WorkspaceCloseProgressViewTests` convention. Without it, `fittingSize`
    /// would answer against a stale or unlaid-out tree, and the hug/cap
    /// assertions below would pass whether or not the panel's sizing actually
    /// works.
    private func layoutSize(for markdown: String) -> CGSize {
        let (model, workspace) = Self.seeded()
        let view = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: markdown)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// A no-op hug/cap (contentHeight stuck at 0, `ScrollView` always at its
    /// 20 pt floor) would still clear a bare `> 0` check, so the meaningful
    /// assertion is that short content settles well short of the cap — a
    /// mechanism that instead always claimed the full `maxHeight` would land
    /// far above this line.
    func testLaysOutAtDeclaredWidthWithNonZeroHeight() {
        let size = layoutSize(for: "## Dev server ready\n\n- API: <http://localhost:8080>\n")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, WorkspaceInfoPanel.maxHeight - 150)
    }

    /// The discriminating half of the hug/cap contract: 200 lines of content
    /// measure far past `maxHeight`, so the `ScrollView` must clamp to (not
    /// merely stay under) the cap. A broken mechanism that never grows past
    /// its 20 pt floor would fail the lower bound here even though it also
    /// trivially satisfies "stays under the cap".
    func testLongMessageNeitherWidensNorExceedsTheHeightCap() {
        let long = (1...200).map { "- endpoint \($0): <http://localhost:80\($0)>" }.joined(separator: "\n")
        let size = layoutSize(for: long)

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.height, WorkspaceInfoPanel.maxHeight)
        // The panel's own 12 pt top/bottom padding sits on top of the capped
        // ScrollView, so the total legitimately exceeds maxHeight; the slack here
        // is that padding (plus a little rounding/scrollbar room), not a loosened cap.
        XCTAssertLessThanOrEqual(size.height, WorkspaceInfoPanel.maxHeight + 40)
    }

    /// NOT a test of the last-resort plain-text fallback in
    /// `MarkdownAttributedString.make` — `.returnPartiallyParsedIfPossible`
    /// already parses an unterminated fence successfully (confirmed directly
    /// against `AttributedString(markdown:options:)`, along with several other
    /// malformed-input probes: a stray backtick, mismatched emphasis, a null
    /// byte, and deeply nested block quotes — none of them threw), so that
    /// fallback path has no known trigger through this app's parsing options.
    /// This only pins that a syntax error a real Foundation parse absorbs still
    /// lays out sanely.
    func testUnterminatedFenceStillParsesAndLaysOut() {
        let size = layoutSize(for: "```\nunterminated fence\n")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, WorkspaceInfoPanel.maxHeight)
    }

    /// The shortest possible content (empty) must floor at `minHeight`, not
    /// collapse to the popover's outer padding alone — the discriminating case
    /// for the floor half of the hug/cap contract, the way
    /// `testLongMessageNeitherWidensNorExceedsTheHeightCap` is for the cap half.
    func testEmptyMessageFloorsAtMinHeight() {
        let size = layoutSize(for: "")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        // The panel's own 12pt top/bottom padding (`WorkspaceInfoPanel.padding`,
        // not visible to this test target) sits outside the floored ScrollView.
        XCTAssertEqual(size.height, WorkspaceInfoPanel.minHeight + 24, accuracy: 0.5)
    }

    /// Pins that `MarkdownTextView` wraps at the panel's own CONTENT width — the
    /// declared `width` minus the panel's inner padding on both sides — not at
    /// `width` itself. That distinction is invisible to
    /// `testLaysOutAtDeclaredWidthWithNonZeroHeight` above: the outer
    /// `.frame(width:)` on the `ScrollView` always reports the panel's declared
    /// width regardless of what width the inner text view actually wrapped at,
    /// so feeding the full width to `MarkdownTextView` would only overflow
    /// silently into the padding rather than fail that test.
    func testContentWrapsAtThePanelWidthMinusItsOwnPadding() {
        let correctContentWidth = WorkspaceInfoPanel.width - 24
        let fullWidth = WorkspaceInfoPanel.width

        // Search for the shortest "word word word …" line whose wrap actually
        // differs between the two widths, rather than hardcoding a word count
        // that could stop discriminating under a different font/rendering
        // environment (a fixed count of 60 did not, in practice: both widths
        // wrapped it to the same number of lines).
        var longLine = ""
        var heightAtCorrectWidth: CGFloat = 0
        var heightAtFullWidth: CGFloat = 0
        for wordCount in stride(from: 20, through: 200, by: 4) {
            longLine = Array(repeating: "word", count: wordCount).joined(separator: " ")
            heightAtCorrectWidth = MarkdownTextView.height(for: longLine, width: correctContentWidth)
            heightAtFullWidth = MarkdownTextView.height(for: longLine, width: fullWidth)
            if heightAtCorrectWidth != heightAtFullWidth { break }
        }
        XCTAssertNotEqual(
            heightAtCorrectWidth, heightAtFullWidth,
            "could not find content that wraps differently at the panel's content width vs. its full width")

        let expectedPanelHeight = min(max(heightAtCorrectWidth, WorkspaceInfoPanel.minHeight), WorkspaceInfoPanel.maxHeight) + 24
        let size = layoutSize(for: longLine)

        XCTAssertEqual(size.height, expectedPanelHeight, accuracy: 1)
    }

    // MARK: - Link routing

    /// An `http(s)` link must open in the workspace's own browser panel — the
    /// same wiring `ControlHandlerTests.testOpenBrowserLoadsInspectorBrowserAndSelectsTab`
    /// pins for `controlOpenBrowser` itself, exercised here through `openURL`'s
    /// own scheme guard rather than called directly.
    func testOpenURLRoutesHTTPSIntoTheWorkspaceBrowser() throws {
        let (model, workspace) = Self.seeded()
        let panel = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: "")
        let url = URL(string: "https://example.com")!

        XCTAssertTrue(panel.openURL(url))

        let ws = try XCTUnwrap(model.workspace(id: workspace.id))
        XCTAssertEqual(ws.inspector.tab, .browser)
        guard case .browser(let opened) = ws.inspector.browser.kind else {
            return XCTFail("inspector browser surface is not a browser kind")
        }
        XCTAssertEqual(opened, url)
    }

    /// Every other scheme must fall through to the system instead — pinned
    /// against a real model so deleting the guard (routing everything into the
    /// workspace browser) cannot pass silently: the inspector would stay off
    /// the `.browser` tab it starts on.
    func testOpenURLLeavesNonHTTPSchemesToTheSystem() throws {
        let (model, workspace) = Self.seeded()
        let panel = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: "")
        let url = URL(string: "file:///etc/hosts")!

        XCTAssertFalse(panel.openURL(url))

        let ws = try XCTUnwrap(model.workspace(id: workspace.id))
        XCTAssertNotEqual(ws.inspector.tab, .browser)
    }
}
