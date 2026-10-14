import Foundation
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Layout tests for the Diff/Browser segmented capsule.
///
/// The failure it guards against is purely geometric and easy to reintroduce:
/// `plusminus` and `globe` do not measure the same, so segments sized to their
/// content come out lopsided and the sliding selection indicator changes size as
/// it moves. `TitleCapsuleMetrics.glyphSlotWidth` is what makes the two halves
/// identical by construction, and the test below pins the assembled control at
/// exactly two equal segments. That the slot clears both symbols, and that they
/// really do measure differently, is pinned with the other glyph-chip symbols by
/// `WorkspaceToolbarActionsTests.testGlyphSlotClearsEverySymbolThatGoesInIt`.
@MainActor
final class InspectorTabSelectorTests: XCTestCase {
    /// A segment is one glyph chip, from the metrics every title-bar chip shares.
    private static var expectedSegmentWidth: CGFloat { TitleCapsuleMetrics.glyphChipWidth }

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

    // MARK: - Helpers

    /// Host the real control with `tab` selected (`nil` = the panel collapsed, so
    /// no indicator is drawn) and return the width it lays out to.
    private func selectorWidth(selecting tab: InspectorTab?) -> CGFloat {
        let (model, seed) = makeSeededModel()
        let workspaceID = seed.id
        if let tab {
            // The workspace starts collapsed, so one toggle expands onto that tab.
            model.toggleInspectorTab(tab, for: workspaceID)
        }
        guard let workspace = model.workspace(id: workspaceID) else {
            XCTFail("seeded workspace disappeared")
            return 0
        }
        return layoutWidth(of: InspectorTabSelector(model: model, workspace: workspace))
    }
}
