import AppKit
import Foundation
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// The sidebar's agent-integration reminders. Two things are worth pinning here.
///
/// The wording and the glyph choice are pure functions, so they are tested directly.
/// Everything else is layout: the view must vanish completely — divider and padding
/// included — when there is nothing to say, and must absorb its widest message inside
/// the narrowest sidebar (220 pt) rather than pushing the column open. Both are
/// measurable headlessly through `NSHostingView.fittingSize`; colours, hover states
/// and the click targets themselves are not (see `headless-swiftui-layout-tests`).
@MainActor
final class AgentIntegrationReminderViewTests: XCTestCase {

    /// The narrow end of `RootView`'s `navigationSplitViewColumnWidth(min:ideal:max:)`,
    /// i.e. the tightest the rows ever have to fit.
    private static let narrowestSidebarWidth: CGFloat = 220

    private func makeModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return AppModel(sessionStore: SessionStore(fileURL: url))
    }

    private func probe(_ model: AppModel, _ statuses: [CodingAgent: AgentIntegrationStatus]) async {
        model.agentIntegrationProbe = { statuses }
        model.refreshAgentIntegrations()
        await model.agentIntegrationTask?.value
    }

    /// Host the real view and return the size it lays out to.
    private func layoutSize(for model: AppModel) -> NSSize {
        measure(AgentIntegrationReminderView(model: model))
    }

    /// Same, in a sidebar column of the given width.
    private func layoutSize(for model: AppModel, width: CGFloat) -> NSSize {
        measure(AgentIntegrationReminderView(model: model).frame(width: width))
    }

    private func measure(_ view: some View) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    // MARK: - Wording and glyphs

    func testMessagesNameTheAgentAndStateTheSituation() {
        let missing = AppModel.AgentIntegrationReminder(agent: .claudeCode, status: .missing, kind: .actionNeeded)
        let outdated = AppModel.AgentIntegrationReminder(
            agent: .claudeCode, status: .outdated(installed: "0.1.0"), kind: .actionNeeded)
        let trust = AppModel.AgentIntegrationReminder(agent: .codex, status: .installed, kind: .trustNotice)

        XCTAssertEqual(AgentIntegrationReminderView.message(for: missing), "Claude Code integration not installed")
        XCTAssertEqual(AgentIntegrationReminderView.message(for: outdated), "Claude Code integration is outdated")
        XCTAssertEqual(
            AgentIntegrationReminderView.message(for: trust), "Codex integration needs approval in /hooks")
    }

    /// The two kinds say different things — "do something" versus "one step from
    /// active" — so they must not wear the same glyph.
    func testTheTwoKindsUseDifferentGlyphs() {
        let actionNeeded = AgentIntegrationReminderView.symbolName(for: .actionNeeded)
        let trustNotice = AgentIntegrationReminderView.symbolName(for: .trustNotice)

        XCTAssertNotEqual(actionNeeded, trustNotice)
        // Both must resolve to real SF Symbols, or the rows render an empty slot.
        XCTAssertNotNil(NSImage(systemSymbolName: actionNeeded, accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: trustNotice, accessibilityDescription: nil))
    }

    // MARK: - Layout

    /// With no reminders the view must contribute *nothing* to the sidebar's stack.
    /// A stray divider or an unconditional padding would show up as height here.
    func testNoRemindersRenderNothingAtAll() {
        let size = layoutSize(for: makeModel())

        XCTAssertEqual(size.height, 0)
        XCTAssertEqual(size.width, 0)
    }

    func testARowIsTallerThanTheEmptyState() async {
        let model = makeModel()
        await probe(model, [.claudeCode: .missing])

        XCTAssertGreaterThan(layoutSize(for: model).height, 0)
    }

    /// Every reminder at once, in the narrowest sidebar: the rows must wrap or
    /// truncate inside 220 pt instead of forcing the column wider, and the two-line
    /// cap must keep the block short enough to leave the footer visible.
    func testAllRemindersFitTheNarrowestSidebar() async {
        let model = makeModel()
        await probe(model, [
            .claudeCode: .missing,
            .codex: .installed,
            .opencode: .outdated(installed: "0.1.0"),
        ])
        XCTAssertEqual(model.agentIntegrationReminders.count, 3)

        let size = layoutSize(for: model, width: Self.narrowestSidebarWidth)

        // The load-bearing half: an unbounded label would report its full single-line
        // width here and drag the whole sidebar column open with it.
        XCTAssertEqual(size.width, Self.narrowestSidebarWidth, accuracy: 0.5)
        // Every reminder at once measures 131 pt; the cap is slack around that, aimed
        // at the block growing tall enough to crowd the "Add Folder…" footer out.
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, 160)
    }
}
