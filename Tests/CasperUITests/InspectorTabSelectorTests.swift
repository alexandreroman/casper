import Foundation
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Layout tests for the Diff/Browser segmented capsule.
///
/// The failure they guard against is purely geometric and easy to reintroduce:
/// `plusminus` and `globe` do not measure the same, so segments sized to their
/// content come out lopsided and the sliding selection indicator changes size as
/// it moves. `InspectorTabSelector.glyphSlotWidth` is what makes the two halves
/// identical by construction, and these tests pin both ends of it — the slot is
/// wide enough for either symbol, and the assembled control measures exactly two
/// equal segments.
@MainActor
final class InspectorTabSelectorTests: XCTestCase {
    /// Mirrors the `.padding(.horizontal, 10)` each segment applies around its
    /// glyph slot; the capsule shell itself adds no width.
    private static let segmentInset: CGFloat = 10

    private static var expectedSegmentWidth: CGFloat {
        InspectorTabSelector.glyphSlotWidth + 2 * segmentInset
    }

    /// The whole control measures exactly two segments of the declared width — so
    /// neither symbol widened its own half. Checked in all three visible states
    /// because the selection indicator is a `.background`, which must never
    /// contribute to the layout.
    func testBothSegmentsMeasureTheSameWidthInEveryState() {
        for tab in [nil, InspectorTab.diff, InspectorTab.browser] as [InspectorTab?] {
            XCTAssertEqual(
                selectorWidth(selecting: tab), 2 * Self.expectedSegmentWidth, accuracy: 0.5,
                "selection \(String(describing: tab))")
        }
    }

    /// Proves the equality above has teeth — the two symbols really do measure
    /// differently, so equal segments can only come from the fixed slot — and that
    /// the slot is generous enough that neither glyph overflows it.
    func testGlyphSlotFitsBothSymbolsThatDoNotMeasureAlike() {
        let plusminus = symbolWidth("plusminus")
        let globe = symbolWidth("globe")

        XCTAssertNotEqual(plusminus, globe, accuracy: 0.5)
        XCTAssertLessThanOrEqual(plusminus, InspectorTabSelector.glyphSlotWidth)
        XCTAssertLessThanOrEqual(globe, InspectorTabSelector.glyphSlotWidth)
    }

    // MARK: - Helpers

    /// Host the real control with `tab` selected (`nil` = the panel collapsed, so
    /// no indicator is drawn) and return the width it lays out to.
    private func selectorWidth(selecting tab: InspectorTab?) -> CGFloat {
        let (model, workspaceID) = Self.seeded()
        if let tab {
            // The workspace starts collapsed, so one toggle expands onto that tab.
            model.toggleInspectorTab(tab, for: workspaceID)
        }
        guard let workspace = model.workspace(id: workspaceID) else {
            XCTFail("seeded workspace disappeared")
            return 0
        }
        let host = NSHostingView(rootView: InspectorTabSelector(model: model, workspace: workspace))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func symbolWidth(_ systemImage: String) -> CGFloat {
        let host = NSHostingView(rootView: Image(systemName: systemImage))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// A model holding one Git-less space + workspace, as in
    /// `WorkspaceInfoButtonTests.seeded()`.
    private static func seeded() -> (AppModel, UUID) {
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))))
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        return (AppModel(sessionStore: store, session: session), ws.id)
    }
}
