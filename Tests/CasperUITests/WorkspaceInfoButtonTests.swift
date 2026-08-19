import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// The button is chrome around one piece of state, so the tests pin the layout
/// behaviours that are easy to break silently: it is always mounted, but its
/// appear/disappear is a property animation (`opacity`/`scaleEffect`/
/// `frame(width:)` keyed on whether there is a message) rather than an
/// insertion/removal `.transition` — the latter does not play inside this
/// view's AppKit-hosted `ToolbarItem`. So with no message it must still
/// measure only `collapsedWidth` (not zero — see that constant's doc) and lay
/// out with real width once a message exists. There is no headless way to
/// drive a real click or hover-dwell through `NSHostingView` in this codebase
/// (see `headless-swiftui-layout-tests`), so `reveal()`'s call into
/// `AppModel.markInfoSeen(for:)` is not exercised through the button itself —
/// only the model primitive it relies on is pinned below.
@MainActor
final class WorkspaceInfoButtonTests: XCTestCase {
    /// A model seeded with one Git-less space + workspace, mirroring
    /// `WorkspaceInfoPanelTests.seeded()`. When `markdown` is non-nil, it is
    /// published via `controlSetInfo` so the workspace starts unread, exactly
    /// as it would after a real `casper info set`.
    private static func seeded(markdown: String?) -> (AppModel, Workspace) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        let model = AppModel(sessionStore: store, session: session)
        if let markdown {
            _ = model.controlSetInfo(markdown: markdown, for: ws.id)
        }
        let workspace = model.workspace(id: ws.id) ?? ws
        return (model, workspace)
    }

    /// With no message the chip itself shows nothing, but the button still
    /// reports `collapsedWidth` — that reserved slot is the only thing
    /// keeping the branch title clear of the diff badge once the chip has
    /// collapsed. See `WorkspaceInfoButton.collapsedWidth`'s doc.
    func testCollapsesToOnlyItsGapWithoutAMessage() {
        let (model, workspace) = Self.seeded(markdown: nil)
        let host = NSHostingView(rootView: WorkspaceInfoButton(model: model, workspace: workspace))

        XCTAssertEqual(host.fittingSize.width, WorkspaceInfoButton.collapsedWidth, accuracy: 0.5)
    }

    /// With a message the chip must report the full `iconSlotWidth`, not merely
    /// some positive width — a `> 0` check alone would still pass if the icon
    /// slot collapsed to the `collapsedWidth` gap, clipping the glyph.
    func testLaysOutWithAMessage() {
        let (model, workspace) = Self.seeded(markdown: "## Ready")
        let host = NSHostingView(rootView: WorkspaceInfoButton(model: model, workspace: workspace))

        XCTAssertEqual(host.fittingSize.width, WorkspaceInfoButton.iconSlotWidth, accuracy: 0.5)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// NOT a test of `WorkspaceInfoButton` — it never constructs one. `reveal()`
    /// calls exactly this AppModel method, but nothing here drives `reveal()`
    /// itself (no headless click/hover), so this only pins the primitive: after
    /// `controlSetInfo` starts a workspace unread, `markInfoSeen` clears it.
    func testMarkInfoSeenClearsTheUnreadFlagThatRevealRelinquishes() {
        let (model, workspace) = Self.seeded(markdown: "## Ready")
        XCTAssertTrue(model.workspace(id: workspace.id)?.infoUnread ?? false)

        model.markInfoSeen(for: workspace.id)

        XCTAssertFalse(model.workspace(id: workspace.id)?.infoUnread ?? true)
    }
}
