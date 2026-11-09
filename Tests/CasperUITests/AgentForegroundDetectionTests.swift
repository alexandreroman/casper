import Foundation
import XCTest
import CasperCore
import UserNotifications
@testable import CasperUI

/// The detection tick driven by each terminal's foreground process: rule-set
/// selection, a shell read as "no agent", and the explicit-authority release on an
/// observed agent exit. No real surface: the foreground PIDs, the processes behind
/// them and the terminal readings are all injected.
@MainActor
final class AgentForegroundDetectionTests: XCTestCase {
    private let shellPID: pid_t = 100
    private let claudePID: pid_t = 200
    private let codexPID: pid_t = 300
    private let vimPID: pid_t = 400

    /// The foreground PID each surface reports, mutated by the tests between ticks.
    private var foregroundPIDs: [UUID: pid_t] = [:]
    /// What the terminal shows, for the surfaces whose viewport is read.
    private var reading = AgentSurfaceReading(viewport: "", title: nil, progress: nil)
    /// How many times the tick read a terminal.
    private var readingCount = 0

    // MARK: Authority release

    func testAgentExitWithEveryPaneAtTheShellReleasesAuthority() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: claudePID, panes[1]: shellPID]
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()
        XCTAssertTrue(model.explicitAuthority.contains(workspace), "an agent still runs")

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertFalse(model.explicitAuthority.contains(workspace), "the agent left; every pane is at the shell")
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .working, "the resolver resumes the run")
        model.runAgentDetectionTick()
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .unknown, "seen, the run settles to unknown")
        XCTAssertEqual(readingCount, 0, "panes at the shell are never read")
    }

    func testPaneRunningAnotherProgramKeepsAuthority() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: claudePID, panes[1]: vimPID]
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertTrue(model.explicitAuthority.contains(workspace), "vim may hide the agent that made the claim")
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .working)
    }

    func testPaneWithoutForegroundKeepsAuthority() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: claudePID]  // the second pane reports none
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertTrue(model.explicitAuthority.contains(workspace), "an unreadable pane may hold the agent")
    }

    func testExplicitErrorSurvivesTheAgentExit() {
        let (model, workspace, panes) = makeModel(paneCount: 1)
        foregroundPIDs = [panes[0]: claudePID]
        XCTAssertTrue(model.controlSetAgentState(.error, for: workspace))
        model.runAgentDetectionTick()

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertTrue(model.explicitAuthority.contains(workspace), "only the agent could have reached error")
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .error)
    }

    func testShellWithoutAnExitKeepsAuthority() {
        let (model, workspace, panes) = makeModel(paneCount: 1)
        foregroundPIDs = [panes[0]: shellPID]
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()
        model.runAgentDetectionTick()

        XCTAssertTrue(model.explicitAuthority.contains(workspace), "no agent was seen leaving")
    }

    /// An agent killed mid-turn leaves its hook's `working` behind: released, it
    /// completes like any detected run, `done` with a passive notification while unseen.
    func testReleasedStaleWorkingCompletesAsDoneWhileUnseen() {
        let (model, background, pane) = makeModelWithBackgroundWorkspace()
        model.isWindowKey = { false }
        var delivered: [(body: String, level: UNNotificationInterruptionLevel)] = []
        model.deliverNotification = { _, body, _, level in delivered.append((body, level)) }
        foregroundPIDs[pane] = claudePID
        XCTAssertTrue(model.controlSetAgentState(.working, for: background))
        runBackgroundSweep(model)

        foregroundPIDs[pane] = shellPID
        runBackgroundSweep(model)
        XCTAssertFalse(model.explicitAuthority.contains(background))
        XCTAssertEqual(model.workspace(id: background)?.agentState, .working, "debounced")
        XCTAssertTrue(delivered.isEmpty)

        runBackgroundSweep(model)
        XCTAssertEqual(model.workspace(id: background)?.agentState, .done)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.body, "Done")
        XCTAssertEqual(delivered.first?.level, .passive)
    }

    /// The prompt died with the agent: released, `blocked` reads `unknown` on the
    /// release tick itself, which proves detection runs in the same pass.
    func testReleasedBlockedResolvesUnknownOnTheReleaseTick() {
        let (model, workspace, panes) = makeModel(paneCount: 1)
        foregroundPIDs = [panes[0]: claudePID]
        XCTAssertTrue(model.controlSetAgentState(.blocked, for: workspace))
        model.runAgentDetectionTick()

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertFalse(model.explicitAuthority.contains(workspace))
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .unknown)
    }

    /// The Stop hook already reported `done`: released while unseen, it stays `done`
    /// and raises nothing beyond the notification the explicit report raised.
    func testReleasedDoneStaysDoneWhileUnseen() {
        let (model, background, pane) = makeModelWithBackgroundWorkspace()
        model.isWindowKey = { false }
        var delivered: [String] = []
        model.deliverNotification = { _, body, _, _ in delivered.append(body) }
        foregroundPIDs[pane] = claudePID
        runBackgroundSweep(model)
        XCTAssertTrue(model.controlSetAgentState(.done, for: background))

        foregroundPIDs[pane] = shellPID
        runBackgroundSweep(model)
        runBackgroundSweep(model)

        XCTAssertFalse(model.explicitAuthority.contains(background))
        XCTAssertEqual(model.workspace(id: background)?.agentState, .done)
        XCTAssertEqual(delivered, ["Done"], "only the explicit report's notification")
    }

    /// The exit edge lasts one tick, but a sibling terminal may not be at its shell on
    /// that tick (a dev server, a prompt's `$(…)`): the exit is remembered until every
    /// terminal is.
    func testExitSeenWhileASiblingIsBusyReleasesOnceItIsBackAtItsShell() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: claudePID, panes[1]: vimPID]
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()

        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()
        XCTAssertTrue(model.explicitAuthority.contains(workspace), "vim still runs on the exit tick")

        foregroundPIDs[panes[1]] = shellPID
        model.runAgentDetectionTick()
        XCTAssertFalse(model.explicitAuthority.contains(workspace), "the remembered exit releases it")
    }

    /// An explicit report after the exit means an agent spoke again: the remembered
    /// exit no longer proves anything.
    func testExplicitReportForgetsARememberedExit() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: claudePID, panes[1]: vimPID]
        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        model.runAgentDetectionTick()
        foregroundPIDs[panes[0]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertTrue(model.controlSetAgentState(.working, for: workspace))
        foregroundPIDs[panes[1]] = shellPID
        model.runAgentDetectionTick()

        XCTAssertTrue(model.explicitAuthority.contains(workspace))
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .working)
    }

    // MARK: Detection

    func testShellOnlyWorkspaceResolvesUnknownWithoutReadingTheTerminal() {
        let (model, workspace, panes) = makeModel(paneCount: 2)
        foregroundPIDs = [panes[0]: shellPID, panes[1]: shellPID]
        reading.viewport = "esc to interrupt"  // a stale screen the shell has not cleared

        model.runAgentDetectionTick()

        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .unknown)
        XCTAssertEqual(readingCount, 0, "a pane at the shell skips the viewport read")
    }

    /// Codex sets no title convention, so a Claude spinner in the title says nothing
    /// about a Codex pane. Anything unidentified still reads every agent's rules.
    func testAgentPaneReadsOnlyItsOwnRuleSet() {
        let (model, workspace, panes) = makeModel(paneCount: 1)
        reading.title = "\u{2807} Claude Code"

        foregroundPIDs = [panes[0]: codexPID]
        model.runAgentDetectionTick()
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .idle)

        foregroundPIDs[panes[0]] = vimPID
        model.runAgentDetectionTick()
        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .working, "vim falls back to every rule set")
    }

    func testSurfaceWithoutLiveViewLeavesTheStateUntouched() {
        let (model, workspace, _) = makeModel(paneCount: 1)
        model.agentSurfaceReader = { _ in nil }  // no live view, and no foreground either

        model.runAgentDetectionTick()

        XCTAssertEqual(model.workspace(id: workspace)?.agentState, .idle)
    }

    // MARK: Tracker upkeep

    /// A tick that skips the background workspaces must not forget their terminals,
    /// or every background agent's exit would go unseen; a closed one is forgotten on
    /// the next tick that visits every workspace.
    func testForegroundOfBackgroundTerminalOutlivesTicksThatSkipIt() {
        let (model, background, pane) = makeModelWithBackgroundWorkspace()
        model.deliverNotification = { _, _, _, _ in }
        foregroundPIDs[pane] = claudePID
        runBackgroundSweep(model)
        model.runAgentDetectionTick()  // skips the background workspace
        XCTAssertEqual(model.foregroundTracker.process(for: pane), .agent(.claudeCode))

        model.removeWorkspace(id: background)
        runBackgroundSweep(model)

        XCTAssertNil(model.foregroundTracker.process(for: pane), "a closed terminal's entry goes")
    }

    func testDumpStateNamesEachForegroundKind() {
        XCTAssertEqual(AppModel.dumpStateName(of: .agent(.claudeCode)), "agent:claudeCode")
        XCTAssertEqual(AppModel.dumpStateName(of: .shell), "shell")
        XCTAssertEqual(AppModel.dumpStateName(of: .other(name: "vim")), "other:vim")
        XCTAssertEqual(AppModel.dumpStateName(of: .unidentified), "unidentified")
    }

    // MARK: Fixtures

    /// A selected workspace of `paneCount` terminals, wired to this test's fakes.
    private func makeModel(paneCount: Int) -> (model: AppModel, workspace: UUID, panes: [UUID]) {
        let panes = (0..<paneCount).map { _ in Surface.terminal(cwd: "/wt") }
        let layout: LayoutNode = panes.count == 1
            ? .leaf(panes[0])
            : .split(
                orientation: .horizontal, children: panes.map { .leaf($0) },
                ratios: panes.map { _ in 1 / Double(panes.count) })
        let workspace = Workspace(name: "main", worktreePath: "/wt", branch: "main", portBase: 40000, layout: layout)
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [workspace])
        let model = makeModel(spaces: [space], selecting: workspace.id)
        installFakes(on: model)
        return (model, workspace.id, panes.map(\.id))
    }

    /// A selected workspace and a background one holding a single terminal, `pane`.
    private func makeModelWithBackgroundWorkspace() -> (model: AppModel, background: UUID, pane: UUID) {
        let selectedPane = Surface.terminal(cwd: "/wt")
        let selected = Workspace(
            name: "main", worktreePath: "/wt", branch: "main", portBase: 40000, layout: .leaf(selectedPane))
        let pane = Surface.terminal(cwd: "/wt-feature")
        let background = Workspace(
            name: "feature", worktreePath: "/wt-feature", branch: "feature", portBase: 40010,
            layout: .leaf(pane), kind: .linked)
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [selected, background])
        let model = makeModel(spaces: [space], selecting: selected.id)
        installFakes(on: model)
        foregroundPIDs[selectedPane.id] = shellPID
        return (model, background.id, pane.id)
    }

    private func installFakes(on model: AppModel) {
        model.processInspector = FakeProcessInspector(processes: [
            shellPID: ProcessSnapshot(
                pid: shellPID, comm: "zsh", imagePath: "/bin/zsh", execPath: "/bin/zsh",
                argv: ["-/bin/zsh"], groupSize: 1),
            claudePID: ProcessSnapshot(
                pid: claudePID, comm: "2.1.319", imagePath: "/Users/me/.local/share/claude/versions/2.1.319",
                execPath: "/Users/me/.local/bin/claude", argv: ["claude"], groupSize: 3),
            codexPID: ProcessSnapshot(
                pid: codexPID, comm: "codex", imagePath: "/Users/me/.local/bin/codex",
                execPath: "/Users/me/.local/bin/codex", argv: ["/Users/me/.local/bin/codex"], groupSize: 2),
            vimPID: ProcessSnapshot(
                pid: vimPID, comm: "vim", imagePath: "/usr/bin/vim", execPath: "/usr/bin/vim",
                argv: ["vim"], groupSize: 1),
        ])
        model.foregroundPIDProvider = { [unowned self] id in foregroundPIDs[id] }
        model.agentSurfaceReader = { [unowned self] _ in
            readingCount += 1
            return reading
        }
    }

    /// Enough ticks for exactly one of them to scrape the background workspaces.
    private func runBackgroundSweep(_ model: AppModel) {
        for _ in 0..<AppModel.backgroundDetectionStride {
            model.runAgentDetectionTick()
        }
    }
}

/// A process table the test writes: every listed PID is readable, any other is gone.
private struct FakeProcessInspector: ProcessInspector {
    let processes: [pid_t: ProcessSnapshot]
    let shellNames: Set<String> = ["zsh", "bash"]

    func key(of pid: pid_t) -> ProcessKey? {
        processes[pid].map { ProcessKey(pid: pid, comm: $0.comm) }
    }

    func snapshot(of pid: pid_t) -> ProcessSnapshot? { processes[pid] }

    func groupSize(of pgid: pid_t) -> Int? { processes[pgid]?.groupSize }
}
