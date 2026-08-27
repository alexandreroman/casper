import AppKit
import CasperCore
import SwiftUI
import XCTest
@testable import CasperUI

/// The shared leading glyph slot of the sidebar's action rows — the pinned footer
/// buttons and the agent-integration reminders above them.
///
/// SF Symbols carry no common width, so laying each glyph out at its intrinsic size
/// starts every title at a different x and the column reads ragged-left. Both
/// properties that keep the column straight are measurable headlessly through
/// `NSHostingView.fittingSize` (see `headless-swiftui-layout-tests`): the slot makes
/// every row's title start at the same x, and the slot is wide enough that no glyph
/// spills out of it into the title. Colours, hover states and the click targets
/// themselves are not measurable here.
///
/// The two families are measured separately, each in the font it renders in — the
/// footer at the sidebar's body font, the denser reminder rows at `.footnote` — since
/// a glyph's intrinsic width follows its font and a slot that fits at one size says
/// nothing about the other.
@MainActor
final class SidebarIconSlotTests: XCTestCase {
    /// The symbols leading the pinned footer buttons.
    private static let footerSymbols = ["folder.badge.plus", "plus"]

    /// The reminder kinds, one per glyph. Read back through the production function so
    /// a change there reaches this test rather than being duplicated.
    private static let reminderKinds: [AppModel.AgentIntegrationReminder.Kind] =
        [.actionNeeded, .trustNotice]

    /// A title held constant across the footer rows under test, so the only thing that
    /// can move the measured width is the glyph ahead of it.
    private static let sharedTitle = "Add Folder…"

    /// An agent status producing each reminder kind, and with it the reminder glyph.
    private static func status(
        for kind: AppModel.AgentIntegrationReminder.Kind
    ) -> AgentIntegrationStatus {
        switch kind {
        case .actionNeeded: return .missing
        case .trustNotice: return .installedAwaitingHookTrust
        }
    }

    /// With one shared slot, a footer row's width no longer depends on which glyph it
    /// leads with — which is exactly "every title starts at the same x", since the
    /// title follows the slot across a fixed `HStack` spacing and a fixed leading
    /// padding.
    ///
    /// Verified to have teeth: without the `.frame(width:)` the `folder.badge.plus`
    /// row measures 3 pt wider than the `plus` row (18 pt against 15 pt of glyph).
    func testEveryFooterGlyphStartsItsTitleAtTheSameX() {
        let widths = Self.footerSymbols.map { layoutSize(forFooterRowWith: $0).width }

        guard let reference = widths.first else {
            return XCTFail("no symbols to measure")
        }
        for (symbol, width) in zip(Self.footerSymbols, widths) {
            XCTAssertEqual(
                width, reference, accuracy: 0.5,
                "\(symbol) shifts its title: the row measures \(width) pt against \(reference) pt")
        }
    }

    /// The same property for the real reminder rows, which the footer rows cannot
    /// stand in for: they render at a different font and carry a trailing dismiss
    /// button.
    ///
    /// A reminder's message is its own — the two kinds say different things — so the
    /// row width is not comparable across kinds directly. What is comparable is
    /// everything the row lays out *around* that message: subtract the width the
    /// message takes on its own, and what is left is the leading padding plus the
    /// glyph slot plus the trailing dismiss button. That number moves with the glyph
    /// unless the slot holds it fixed.
    func testEveryReminderGlyphStartsItsMessageAtTheSameX() async {
        var offsets: [CGFloat] = []
        for kind in Self.reminderKinds {
            offsets.append(await reminderMessageOffset(for: kind))
        }

        guard let reference = offsets.first else {
            return XCTFail("no reminder kinds to measure")
        }
        for (kind, offset) in zip(Self.reminderKinds, offsets) {
            XCTAssertEqual(
                offset, reference, accuracy: 0.5,
                "\(kind) shifts its message: it starts at \(offset) pt against \(reference) pt")
        }
    }

    /// The equality above holds for any slot width, including one too narrow: a
    /// `.frame(width:)` reports its own size whatever it contains, so an oversized
    /// glyph would silently overhang into the title instead of failing. Assert the
    /// fit separately, against each glyph's intrinsic width at the font its row uses.
    func testTheSlotFitsEveryGlyphItHolds() {
        for symbol in Self.footerSymbols {
            assertFits(symbol, layoutSize(for: Image(systemName: symbol)).width)
        }
        for kind in Self.reminderKinds {
            let symbol = AgentIntegrationReminderView.symbolName(for: kind)
            assertFits(symbol, layoutSize(for: Image(systemName: symbol).font(.footnote)).width)
        }
    }

    private func assertFits(_ symbol: String, _ intrinsicWidth: CGFloat) {
        XCTAssertLessThanOrEqual(
            intrinsicWidth, SidebarActionButtonStyle.iconSlotWidth,
            "\(symbol) is \(intrinsicWidth) pt wide and overhangs the slot")
    }

    /// The x at which a reminder row of `kind` starts its message, measured on the
    /// production view driven by the production probe — a single reminder, so the
    /// view's width is that one row's width.
    private func reminderMessageOffset(
        for kind: AppModel.AgentIntegrationReminder.Kind
    ) async -> CGFloat {
        let model = makeModel()
        // Resolved here rather than inside the probe: the probe runs off the main actor.
        let statuses: [CodingAgent: AgentIntegrationStatus] = [.claudeCode: Self.status(for: kind)]
        model.agentIntegrationProbe = { statuses }
        model.refreshAgentIntegrations()
        await model.agentIntegrationTask?.value
        guard let reminder = model.agentIntegrationReminders.first,
              model.agentIntegrationReminders.count == 1, reminder.kind == kind else {
            XCTFail("expected exactly one \(kind) reminder")
            return .nan
        }

        let rowWidth = layoutSize(for: AgentIntegrationReminderView(model: model)).width
        let message = Text(AgentIntegrationReminderView.message(for: reminder))
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .font(.footnote)
        return rowWidth - layoutSize(for: message).width
    }

    /// A real footer row, hosted the way `SidebarFooter` stacks it.
    private func layoutSize(forFooterRowWith symbol: String) -> NSSize {
        let row = SidebarFooterButton(title: Self.sharedTitle, systemImage: symbol, action: {})
        return layoutSize(for: row)
    }

    private func layoutSize(for view: some View) -> NSSize {
        let host = NSHostingView(rootView: VStack(spacing: 0) { view })
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
