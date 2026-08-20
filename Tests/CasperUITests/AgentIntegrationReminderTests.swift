import Foundation
import XCTest
import CasperCore
@testable import CasperUI

/// The `AppModel` half of the agent-integration feature: turning a probe result plus
/// the user's dismissals into the ordered reminder list the sidebar renders, and
/// keeping those dismissals alive across launches.
///
/// Every test drives the injected `agentIntegrationProbe` seam, so nothing here
/// spawns a login shell or reads the real home directory.
@MainActor
final class AgentIntegrationReminderTests: XCTestCase {

    private func makeStore() -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return (SessionStore(fileURL: url), url)
    }

    /// Publish one stubbed probe result and wait for it to land. The probe runs off
    /// the main actor, so the model's own task is what tells us it is done.
    private func probe(_ model: AppModel, _ statuses: [CodingAgent: AgentIntegrationStatus]) async {
        model.agentIntegrationProbe = { statuses }
        model.refreshAgentIntegrations()
        await model.agentIntegrationTask?.value
    }

    private func remindedAgents(_ model: AppModel) -> [CodingAgent] {
        model.agentIntegrationReminders.map(\.agent)
    }

    /// The published line for one agent, looked up the way the sidebar row does —
    /// dismissal is keyed by the line, not by the agent.
    private func reminder(_ model: AppModel, _ agent: CodingAgent) throws -> AppModel.AgentIntegrationReminder {
        try XCTUnwrap(model.agentIntegrationReminders.first { $0.agent == agent })
    }

    private func dismiss(_ model: AppModel, _ agent: CodingAgent) throws {
        model.dismissAgentReminder(try reminder(model, agent))
    }

    // MARK: - Which statuses earn a reminder

    func testMissingAndOutdatedProduceReminders() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        await probe(model, [.claudeCode: .missing, .codex: .outdated(installed: "0.1.0")])

        XCTAssertEqual(remindedAgents(model), [.claudeCode, .codex])
        XCTAssertEqual(model.agentIntegrationReminders[1].status, .outdated(installed: "0.1.0"))
    }

    func testNotInstalledAndInstalledProduceNoReminder() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        // `.notInstalled` means the user does not have that agent at all, and
        // `.installed` means there is nothing to fix: both render nothing. Codex is
        // the exception, covered by the hook-trust tests below.
        await probe(model, [.claudeCode: .installed, .codex: .notInstalled, .opencode: .installed])

        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)
    }

    func testMissingAndOutdatedAreActionNeededLines() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        await probe(model, [.claudeCode: .missing, .opencode: .outdated(installed: "0.1.0")])

        XCTAssertEqual(model.agentIntegrationReminders.map(\.kind), [.actionNeeded, .actionNeeded])
    }

    // MARK: - The hook-trust notice
    //
    // Codex hashes non-managed command hooks and will not run them until the user
    // approves them through `/hooks` in its TUI, so a Codex integration can be fully
    // installed on disk and completely inert. That is the one case where `.installed`
    // still has something to say.

    func testInstalledCodexProducesATrustNotice() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        await probe(model, [.codex: .installed])

        let line = try reminder(model, .codex)
        XCTAssertEqual(line.kind, .trustNotice)
        XCTAssertEqual(line.status, .installed)
    }

    func testInstalledAgentsThatNeedNoTrustProduceNothing() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        // Only an agent flagged `requiresHookTrust` earns a notice; the other two are
        // simply done once installed.
        XCTAssertFalse(CodingAgent.claudeCode.requiresHookTrust)
        XCTAssertFalse(CodingAgent.opencode.requiresHookTrust)
        await probe(model, [.claudeCode: .installed, .opencode: .installed])

        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)
    }

    func testNotInstalledCodexProducesNothing() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        // No Codex CLI on the machine: the hook-trust caveat is irrelevant, and
        // advertising an integration for a tool the user does not have is noise.
        await probe(model, [.codex: .notInstalled])

        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)
    }

    func testTrustNoticeStaysDismissedAcrossARefreshThatStillReportsInstalled() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.codex: .installed])
        try dismiss(model, .codex)
        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)

        // The regression the separate dismissal key exists to prevent: the auto-clear
        // retires an agent's dismissal once it reports `.installed`, which is the only
        // status a trust notice ever appears under. Sharing the key would un-dismiss
        // the notice on the very next probe, making it impossible to silence.
        await probe(model, [.codex: .installed])

        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)
    }

    func testDismissingTheTrustNoticeLeavesALaterActionNeededLineAlone() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.codex: .installed])
        try dismiss(model, .codex)

        // The user silenced "approve it in /hooks". Losing the integration afterwards
        // is a different problem and still deserves a line.
        await probe(model, [.codex: .missing])

        XCTAssertEqual(model.agentIntegrationReminders.map(\.kind), [.actionNeeded])
    }

    func testDismissingAnActionNeededLineLeavesTheTrustNoticeAlone() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.codex: .missing])
        try dismiss(model, .codex)
        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)

        // Installing the integration retires that dismissal, and surfaces the notice
        // the user has never seen, let alone dismissed.
        await probe(model, [.codex: .installed])

        XCTAssertEqual(model.agentIntegrationReminders.map(\.kind), [.trustNotice])
    }

    func testTrustNoticeDismissalUsesItsOwnPersistedKey() async throws {
        let (store, url) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.codex: .installed])
        try dismiss(model, .codex)

        model.flushPendingSave()
        let reloaded = try SessionStore(fileURL: url).load()

        // Distinct from the agent's own `reminderID`, which is what the action-needed
        // line dismisses under.
        XCTAssertEqual(reloaded.dismissedAgentReminders, ["\(CodingAgent.codex.reminderID)-trust"])
    }

    func testReminderCarriesTheDocumentationURL() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        await probe(model, [.codex: .missing])

        let reminder = try XCTUnwrap(model.agentIntegrationReminders.first)
        XCTAssertEqual(reminder.documentationURL, CodingAgent.codex.documentationURL)
        // The hook-trust caveat is the UI's to word, but it has to be reachable here.
        XCTAssertTrue(reminder.agent.requiresHookTrust)
    }

    func testReminderOrderFollowsAllCasesNotDictionaryOrder() async {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)

        // A `[CodingAgent: …]` iterates in an order that depends on a per-process
        // hash seed, so the published list must be driven by `allCases` instead —
        // otherwise the sidebar's lines shuffle from one launch to the next.
        await probe(model, [.opencode: .missing, .claudeCode: .missing, .codex: .missing])

        XCTAssertEqual(remindedAgents(model), CodingAgent.allCases)
    }

    // MARK: - Dismissal

    func testDismissRemovesOnlyThatAgentsReminder() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.claudeCode: .missing, .codex: .missing, .opencode: .missing])

        try dismiss(model, .codex)

        XCTAssertEqual(remindedAgents(model), [.claudeCode, .opencode])
    }

    func testDismissalSurvivesPersistAndReload() async throws {
        let (store, url) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.claudeCode: .missing, .codex: .missing])
        try dismiss(model, .claudeCode)

        // The disk write is backgrounded; flush so the reload below sees it.
        model.flushPendingSave()
        let reloadedStore = SessionStore(fileURL: url)
        let reloadedSession = try reloadedStore.load()

        // Persisted under `reminderID` ("claude-code"), never the enum's `rawValue`
        // ("claudeCode") — the wrong key would make the dismissal a silent no-op.
        XCTAssertEqual(reloadedSession.dismissedAgentReminders, [CodingAgent.claudeCode.reminderID])

        let reloadedModel = AppModel(sessionStore: reloadedStore, session: reloadedSession)
        await probe(reloadedModel, [.claudeCode: .missing, .codex: .missing])
        XCTAssertEqual(remindedAgents(reloadedModel), [.codex])
    }

    func testDismissalIsNotWipedByALaterPersist() async throws {
        let (store, url) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.claudeCode: .missing])
        try dismiss(model, .claudeCode)

        // Any unrelated save re-encodes the whole session; the dismissal has to
        // travel with it rather than being dropped on the floor.
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/unrelated"), probe: { _ in nil })
        model.flushPendingSave()

        let reloaded = try SessionStore(fileURL: url).load()
        XCTAssertEqual(reloaded.dismissedAgentReminders, [CodingAgent.claudeCode.reminderID])
    }

    func testInstalledClearsTheDismissalSoALaterRegressionRemindsAgain() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.claudeCode: .missing])
        try dismiss(model, .claudeCode)

        // Fixing the integration retires the dismissal: it silenced that problem,
        // not the agent for good.
        await probe(model, [.claudeCode: .installed])
        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)

        // So breaking it again is worth a reminder.
        await probe(model, [.claudeCode: .missing])
        XCTAssertEqual(remindedAgents(model), [.claudeCode])
    }

    func testInstalledClearsOnlyTheHealedAgentsDismissal() async throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        await probe(model, [.claudeCode: .missing, .codex: .missing])
        try dismiss(model, .claudeCode)
        try dismiss(model, .codex)

        await probe(model, [.claudeCode: .installed, .codex: .missing])

        // Codex is still broken and still dismissed, so it stays silent.
        XCTAssertTrue(model.agentIntegrationReminders.isEmpty)
        await probe(model, [.claudeCode: .missing, .codex: .missing])
        XCTAssertEqual(remindedAgents(model), [.claudeCode])
    }

    // MARK: - Probe throttle

    func testThrottleAllowsTheFirstProbe() {
        XCTAssertTrue(AppModel.shouldProbeAgentIntegrations(lastProbeAt: nil, now: Date()))
    }

    func testThrottleRejectsARepeatWithinTheInterval() {
        let now = Date()
        let justInside = now.addingTimeInterval(-AppModel.agentIntegrationProbeThrottle + 1)
        XCTAssertFalse(AppModel.shouldProbeAgentIntegrations(lastProbeAt: justInside, now: now))
    }

    func testThrottleAllowsAProbeOnceTheIntervalHasElapsed() {
        let now = Date()
        let atBoundary = now.addingTimeInterval(-AppModel.agentIntegrationProbeThrottle)
        XCTAssertTrue(AppModel.shouldProbeAgentIntegrations(lastProbeAt: atBoundary, now: now))

        let wellPast = now.addingTimeInterval(-AppModel.agentIntegrationProbeThrottle - 1)
        XCTAssertTrue(AppModel.shouldProbeAgentIntegrations(lastProbeAt: wellPast, now: now))
    }
}
