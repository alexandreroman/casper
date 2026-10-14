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
/// its declared `intrinsicWidth` — exactly two equal segments — and checks that
/// the two symbols really do measure differently. That the slot clears both is
/// pinned with the other glyph-chip symbols by
/// `WorkspaceToolbarActionsTests.testGlyphSlotClearsEverySymbolThatGoesInIt`.
@MainActor
final class InspectorTabSelectorTests: XCTestCase {
    /// The whole control measures its declared width of two glyph chips — so
    /// neither symbol widened its own half. Checked in all three visible states
    /// because the selection indicator is a `.background`, which must never
    /// contribute to the layout.
    func testBothSegmentsMeasureTheSameWidthInEveryState() {
        XCTAssertNotEqual(
            symbolWidth("plusminus"), symbolWidth("globe"), accuracy: 0.5,
            "the two symbols measure alike, so equal halves prove nothing")
        for tab in [nil, InspectorTab.diff, InspectorTab.browser] as [InspectorTab?] {
            XCTAssertEqual(
                selectorWidth(selecting: tab), InspectorTabSelector.intrinsicWidth, accuracy: 0.5,
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
