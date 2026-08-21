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

    /// A version string as unreasonable as the sources allow: versions are read from
    /// other tools' files — a Codex cache *directory name*, a Claude registry field
    /// — so nothing on the way in bounds their length or keeps them on one line.
    private static let absurdVersion =
        String(repeating: "9.", count: 200) + "\n" + String(repeating: "x", count: 400)

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

    /// The subject is wrapped the way `SidebarView` wraps it. Its body is a
    /// `TupleView` of a `Divider` and a `VStack`, which only flattens into a stack —
    /// hosted bare, `NSHostingView` supplies container semantics of its own and the
    /// number measured is not the one the sidebar gets.
    private func measure(_ view: some View) -> NSSize {
        let host = NSHostingView(rootView: VStack(spacing: 0) { view })
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
        XCTAssertEqual(
            AgentIntegrationReminderView.message(for: outdated), "Claude Code integration is outdated (0.1.0)")
        XCTAssertEqual(AgentIntegrationReminderView.message(for: trust), "Codex integration needs approval")
    }

    func testAnAbsurdVersionIsCappedInTheMessage() {
        let reminder = AppModel.AgentIntegrationReminder(
            agent: .claudeCode, status: .outdated(installed: Self.absurdVersion), kind: .actionNeeded)

        let message = AgentIntegrationReminderView.message(for: reminder)

        XCTAssertTrue(message.hasPrefix("Claude Code integration is outdated ("))
        XCTAssertTrue(message.hasSuffix("…)"))
        // The sentence plus a version capped to its budget, and nothing else.
        XCTAssertEqual(
            message.count,
            "Claude Code integration is outdated ()".count + AgentIntegrationReminderView.maxDisplayedVersionLength)
        // A newline inside the version would spend one of the row's two lines on a
        // hard break.
        XCTAssertFalse(message.contains("\n"))
    }

    /// A version made only of whitespace has nothing to report, so the line says what
    /// it said before the version was ever shown — never an empty parenthesis.
    func testAnEmptyVersionLeavesTheLineBare() {
        let reminder = AppModel.AgentIntegrationReminder(
            agent: .claudeCode, status: .outdated(installed: "  \n "), kind: .actionNeeded)

        XCTAssertEqual(AgentIntegrationReminderView.message(for: reminder), "Claude Code integration is outdated")
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

    /// The message cap, measured rather than asserted on the string: a row carrying a
    /// pathological version must lay out like a row carrying a real one.
    func testAnAbsurdVersionDoesNotWidenTheRow() async {
        let sane = makeModel()
        await probe(sane, [.claudeCode: .outdated(installed: "0.1.0")])
        let absurd = makeModel()
        await probe(absurd, [.claudeCode: .outdated(installed: Self.absurdVersion)])

        let saneWidth = layoutSize(for: sane).width
        XCTAssertGreaterThan(saneWidth, 0)

        // Uncapped, the same row reports its whole version on one line — a four-figure
        // width, which is what would drag the sidebar column open behind it. The slack
        // covers the few extra characters a capped version is allowed to add.
        XCTAssertLessThan(layoutSize(for: absurd).width, saneWidth + 80)
        // And inside the column it still wraps rather than pushing it wider.
        XCTAssertEqual(
            layoutSize(for: absurd, width: Self.narrowestSidebarWidth).width,
            Self.narrowestSidebarWidth,
            accuracy: 0.5)
    }
}
