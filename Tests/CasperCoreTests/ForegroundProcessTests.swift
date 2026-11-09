import Foundation
import XCTest
@testable import CasperCore

final class ForegroundProcessTests: XCTestCase {

    /// `/etc/shells` on a stock macOS, as basenames.
    private let etcShells: Set<String> = ["bash", "csh", "dash", "ksh", "sh", "tcsh", "zsh"]

    private func classify(_ snapshot: ProcessSnapshot?, shellNames: Set<String>? = nil) -> ForegroundProcess {
        ForegroundProcessClassifier.classify(snapshot, shellNames: shellNames ?? etcShells)
    }

    // MARK: - Fixtures measured on a real Mac (design § 1)

    /// Claude Code's native installer symlinks `~/.local/bin/claude` to a versioned
    /// file, so the kernel's `p_comm` and the resolved image are the version string.
    private let nativeClaude = ProcessSnapshot(
        pid: 200, comm: "2.1.319",
        imagePath: "/Users/alex/.local/share/claude/versions/2.1.319",
        execPath: "/Users/alex/.local/bin/claude",
        argv: ["claude"], groupSize: 3)

    /// An npm install: the postinstall hard-links the native binary over `bin/claude.exe`.
    private let npmClaude = ProcessSnapshot(
        pid: 201, comm: "claude.exe",
        imagePath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
        execPath: "/opt/homebrew/bin/claude",
        argv: ["claude"], groupSize: 2)

    private let standaloneCodex = ProcessSnapshot(
        pid: 202, comm: "codex",
        imagePath: "/Users/alex/.local/bin/codex",
        execPath: "/Users/alex/.local/bin/codex",
        argv: ["/Users/alex/.local/bin/codex"], groupSize: 1)

    private let homebrewOpencode = ProcessSnapshot(
        pid: 203, comm: "opencode",
        imagePath: "/opt/homebrew/Cellar/opencode/1.19.5/bin/opencode",
        execPath: "/opt/homebrew/bin/opencode",
        argv: ["/opt/homebrew/bin/opencode"], groupSize: 2)

    /// `@openai/codex`'s shim when Node cannot `execve`: node leads the group.
    private let nodeCodexShim = ProcessSnapshot(
        pid: 204, comm: "node",
        imagePath: "/opt/homebrew/Cellar/node/24.1.0/bin/node",
        execPath: "/opt/homebrew/bin/node",
        argv: ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"], groupSize: 2)

    /// The login shell `login -flp` launched, at its prompt.
    private func loginZsh(groupSize: Int?) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: 100, comm: "zsh", imagePath: "/bin/zsh", execPath: "/bin/zsh",
            argv: ["-/bin/zsh"], groupSize: groupSize)
    }

    // MARK: - Classifier: agents

    func testNativeClaudeIsIdentifiedThroughArgv0DespiteItsVersionComm() {
        XCTAssertEqual(classify(nativeClaude), .agent(.claudeCode))
    }

    func testNpmClaudeIsIdentified() {
        XCTAssertEqual(classify(npmClaude), .agent(.claudeCode))
    }

    func testDotExeImageAloneIdentifiesTheAgent() {
        // argv unreadable: only the `.exe` image and comm are left to go on.
        let snapshot = ProcessSnapshot(
            pid: 205, comm: "opencode.exe",
            imagePath: "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe",
            execPath: nil, argv: [], groupSize: 1)
        XCTAssertEqual(classify(snapshot), .agent(.opencode))
    }

    func testStandaloneCodexIsIdentified() {
        XCTAssertEqual(classify(standaloneCodex), .agent(.codex))
    }

    func testHomebrewOpencodeIsIdentified() {
        XCTAssertEqual(classify(homebrewOpencode), .agent(.opencode))
    }

    func testNodeRunningTheCodexShimIsCodex() {
        XCTAssertEqual(classify(nodeCodexShim), .agent(.codex))
    }

    func testInterpreterScriptExtensionsAreStripped() {
        for script in ["/x/codex.mjs", "/x/codex.cjs", "/x/codex"] {
            var snapshot = nodeCodexShim
            snapshot.argv = ["bun", script]
            XCTAssertEqual(classify(snapshot), .agent(.codex), script)
        }
    }

    func testNodeRunningAnUnrelatedScriptIsOther() {
        var snapshot = nodeCodexShim
        snapshot.argv = ["node", "/srv/server.js"]
        XCTAssertEqual(classify(snapshot), .other(name: "node"))
    }

    func testArgv1CountsOnlyBehindAnInterpreter() {
        let snapshot = ProcessSnapshot(
            pid: 206, comm: "vim", imagePath: "/usr/bin/vim", execPath: "/usr/bin/vim",
            argv: ["vim", "codex.js"], groupSize: 1)
        XCTAssertEqual(classify(snapshot), .other(name: "vim"))
    }

    func testAgentNameMatchIsExactNotASubstring() {
        let snapshot = ProcessSnapshot(
            pid: 207, comm: "claude-monitor",
            imagePath: "/opt/homebrew/bin/claude-monitor", execPath: "/opt/homebrew/bin/claude-monitor",
            argv: ["claude-monitor"], groupSize: 1)
        XCTAssertEqual(classify(snapshot), .other(name: "claude-monitor"))
    }

    func testAgentWinsOverAShellName() {
        // A shell-named image answering to an agent's name is the agent.
        let snapshot = ProcessSnapshot(
            pid: 208, comm: "zsh", imagePath: "/bin/zsh", execPath: "/bin/zsh",
            argv: ["claude"], groupSize: 1)
        XCTAssertEqual(classify(snapshot), .agent(.claudeCode))
    }

    // MARK: - Classifier: shells and the rest

    func testLoneLoginShellIsShell() {
        XCTAssertEqual(classify(loginZsh(groupSize: 1)), .shell)
    }

    func testShellLeadingAGroupIsOther() {
        // A non-interactive shell running a script shares its group with its children.
        XCTAssertEqual(classify(loginZsh(groupSize: 2)), .other(name: "zsh"))
    }

    func testShellWithUnknownGroupSizeIsOther() {
        XCTAssertEqual(classify(loginZsh(groupSize: nil)), .other(name: "zsh"))
    }

    func testDashPrefixedArgv0IsAShell() {
        let snapshot = ProcessSnapshot(
            pid: 101, comm: "", imagePath: nil, execPath: nil, argv: ["-zsh"], groupSize: 1)
        XCTAssertEqual(classify(snapshot), .shell)
    }

    func testShellOutsideEtcShellsNeedsTheLoginShellName() {
        let fish = ProcessSnapshot(
            pid: 102, comm: "fish", imagePath: "/opt/homebrew/bin/fish", execPath: "/opt/homebrew/bin/fish",
            argv: ["-fish"], groupSize: 1)
        XCTAssertEqual(classify(fish), .other(name: "fish"))
        XCTAssertEqual(classify(fish, shellNames: etcShells.union(["fish"])), .shell)
    }

    func testUnreadableProcessIsUnidentified() {
        XCTAssertEqual(classify(nil), .unidentified)
    }

    // MARK: - Shell names

    func testShellNamesJoinEtcShellsAndTheLoginShell() {
        let etcShellsFile = """
            # List of acceptable shells for chpass(1).
            # Ftpd will not allow users to connect who are not using
            # one of these shells.

            /bin/bash\r
            /bin/zsh
            """
        let names = LibprocProcessInspector.shellNames(etcShells: etcShellsFile, loginShell: "/opt/homebrew/bin/fish")
        XCTAssertEqual(names, ["bash", "zsh", "fish"])
    }

    func testShellNamesWithoutALoginShell() {
        XCTAssertEqual(LibprocProcessInspector.shellNames(etcShells: "/bin/sh\n", loginShell: nil), ["sh"])
    }

    // MARK: - KERN_PROCARGS2 parsing

    private func procargs(argc: Int32, _ strings: [String], padding: Int) -> ArraySlice<UInt8> {
        var record = withUnsafeBytes(of: argc) { Array($0) }
        for (index, string) in strings.enumerated() {
            record += Array(string.utf8) + [0]
            if index == 0 {
                record += [UInt8](repeating: 0, count: padding)
            }
        }
        return record[...]
    }

    func testParsesExecPathAndArgvUpToArgc() throws {
        // The exec path, its padding, two arguments, then the environment.
        let record = procargs(argc: 2, ["/bin/zsh", "-zsh", "-l", "HOME=/Users/alex"], padding: 3)
        let parsed = try XCTUnwrap(LibprocProcessInspector.parseArguments(record))
        XCTAssertEqual(parsed.execPath, "/bin/zsh")
        XCTAssertEqual(parsed.argv, ["-zsh", "-l"])
    }

    func testTruncatedRecordsParseWithoutTrapping() {
        XCTAssertNil(LibprocProcessInspector.parseArguments([1, 0]))
        XCTAssertNil(LibprocProcessInspector.parseArguments(procargs(argc: 1, [], padding: 0)))
        // An argc larger than the arguments present stops at the end of the data.
        let short = procargs(argc: 5, ["/bin/zsh", "zsh"], padding: 0)
        XCTAssertEqual(LibprocProcessInspector.parseArguments(short)?.argv, ["zsh"])
    }

    // MARK: - Live inspector

    func testLiveInspectorReadsTheTestProcess() throws {
        let inspector = LibprocProcessInspector()
        let pid = getpid()

        let key = try XCTUnwrap(inspector.key(of: pid))
        XCTAssertEqual(key.pid, pid)
        XCTAssertFalse(key.comm.isEmpty)

        let snapshot = try XCTUnwrap(inspector.snapshot(of: pid))
        XCTAssertEqual(snapshot.comm, key.comm)
        XCTAssertFalse(snapshot.argv.isEmpty)
        XCTAssertNotNil(snapshot.execPath)
        XCTAssertNotNil(snapshot.imagePath)

        let groupSize = try XCTUnwrap(inspector.groupSize(of: getpgrp()))
        XCTAssertGreaterThanOrEqual(groupSize, 1)
        XCTAssertFalse(inspector.shellNames.isEmpty)
    }

    func testLiveInspectorAnswersNilForANonexistentProcess() {
        let inspector = LibprocProcessInspector()
        // PIDs top out at 99_998 on macOS; this one can never exist.
        let pid: pid_t = 999_999
        XCTAssertNil(inspector.key(of: pid))
        XCTAssertNil(inspector.snapshot(of: pid))
        XCTAssertNil(inspector.groupSize(of: pid))
    }

    // MARK: - Tracker

    private let surface = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!
    private let otherSurface = UUID(uuidString: "FEDCBA98-7654-4321-ABCD-EF0123456789")!

    func testCacheHitTakesNoSnapshot() {
        let inspector = FakeProcessInspector([standaloneCodex])
        var tracker = ForegroundTracker()

        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 202, inspector: inspector).process,
            .agent(.codex))
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 202, inspector: inspector).process,
            .agent(.codex))
        XCTAssertEqual(inspector.snapshotCalls, 1)
        XCTAssertEqual(inspector.keyCalls, 2)
        XCTAssertEqual(inspector.groupSizeCalls, 0, "only a shell re-checks its group")
    }

    func testCommChangeWithTheSamePIDReclassifies() {
        // `exec claude` from the shell keeps the PID.
        let inspector = FakeProcessInspector([loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()
        XCTAssertEqual(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process, .shell)

        var execedClaude = nativeClaude
        execedClaude.pid = 100
        inspector.processes[100] = execedClaude
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process,
            .agent(.claudeCode))
        XCTAssertEqual(inspector.snapshotCalls, 2)
    }

    func testCachedShellRechecksItsGroupEveryCall() {
        let inspector = FakeProcessInspector([loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()
        XCTAssertEqual(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process, .shell)

        inspector.processes[100]?.groupSize = 2
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process,
            .other(name: "zsh"))

        inspector.processes[100]?.groupSize = 1
        XCTAssertEqual(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process, .shell)

        XCTAssertEqual(inspector.snapshotCalls, 1)
        XCTAssertEqual(inspector.groupSizeCalls, 2)
    }

    func testShellFirstSeenWithAChildBecomesShellOnceAlone() {
        // A prompt's command substitution briefly shares the shell's group; the
        // classification must not stay `.other` for the life of the shell.
        let inspector = FakeProcessInspector([loginZsh(groupSize: 2)])
        var tracker = ForegroundTracker()
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process,
            .other(name: "zsh"))

        inspector.processes[100]?.groupSize = 1
        XCTAssertEqual(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).process, .shell)
        XCTAssertEqual(inspector.snapshotCalls, 1)
    }

    func testAgentToShellReportsTheExitOnce() {
        let inspector = FakeProcessInspector([nativeClaude, loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()

        XCTAssertFalse(tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector).agentExited)
        let exit = tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector)
        XCTAssertEqual(exit, ForegroundObservation(process: .shell, agentExited: true))
        XCTAssertFalse(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).agentExited)
    }

    func testExitSurvivesAnUnidentifiedTickInBetween() {
        let inspector = FakeProcessInspector([nativeClaude, loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        // The dead agent's group is still foreground, but its leader is gone.
        inspector.processes[200] = nil
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector),
            ForegroundObservation(process: .unidentified, agentExited: false))
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: nil, inspector: inspector),
            ForegroundObservation(process: .unidentified, agentExited: false))
        XCTAssertTrue(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).agentExited)
    }

    func testExitSurvivesTheShellsOwnCommandSubstitution() {
        // Back at the prompt, the shell's `$(…)` briefly shares its group: that
        // `.other` tick must not hide the agent the exit is measured against.
        let inspector = FakeProcessInspector([nativeClaude, loginZsh(groupSize: 2)])
        var tracker = ForegroundTracker()

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector),
            ForegroundObservation(process: .other(name: "zsh"), agentExited: false))
        inspector.processes[100]?.groupSize = 1
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector),
            ForegroundObservation(process: .shell, agentExited: true))
        XCTAssertFalse(tracker.observe(surface: surface, foregroundPID: 100, inspector: inspector).agentExited)
    }

    func testAgentRestartIsNotAnExit() {
        var restarted = nativeClaude
        restarted.pid = 300
        let inspector = FakeProcessInspector([nativeClaude, restarted])
        var tracker = ForegroundTracker()

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 300, inspector: inspector),
            ForegroundObservation(process: .agent(.claudeCode), agentExited: false))
    }

    func testAgentToOtherIsNotAnExit() {
        let vim = ProcessSnapshot(
            pid: 400, comm: "vim", imagePath: "/usr/bin/vim", execPath: "/usr/bin/vim", argv: ["vim"], groupSize: 1)
        let inspector = FakeProcessInspector([nativeClaude, vim])
        var tracker = ForegroundTracker()

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        XCTAssertEqual(
            tracker.observe(surface: surface, foregroundPID: 400, inspector: inspector),
            ForegroundObservation(process: .other(name: "vim"), agentExited: false))
    }

    func testSurfacesAreTrackedIndependently() {
        let inspector = FakeProcessInspector([nativeClaude, loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        // Another pane at its shell has seen no agent leave.
        XCTAssertFalse(tracker.observe(surface: otherSurface, foregroundPID: 100, inspector: inspector).agentExited)
        XCTAssertEqual(tracker.process(for: surface), .agent(.claudeCode))
        XCTAssertEqual(tracker.process(for: otherSurface), .shell)
    }

    func testProcessForReportsTheLastObservation() {
        let inspector = FakeProcessInspector([nativeClaude])
        var tracker = ForegroundTracker()
        XCTAssertNil(tracker.process(for: surface))

        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        XCTAssertEqual(tracker.process(for: surface), .agent(.claudeCode))
        _ = tracker.observe(surface: surface, foregroundPID: nil, inspector: inspector)
        XCTAssertEqual(tracker.process(for: surface), .unidentified)
    }

    func testRetainDropsClosedSurfaces() {
        let inspector = FakeProcessInspector([nativeClaude, loginZsh(groupSize: 1)])
        var tracker = ForegroundTracker()
        _ = tracker.observe(surface: surface, foregroundPID: 200, inspector: inspector)
        _ = tracker.observe(surface: otherSurface, foregroundPID: 200, inspector: inspector)

        tracker.retain(surfaces: [surface])

        XCTAssertNotNil(tracker.process(for: surface))
        XCTAssertNil(tracker.process(for: otherSurface))
        // The dropped surface's agent history went with it.
        XCTAssertFalse(tracker.observe(surface: otherSurface, foregroundPID: 100, inspector: inspector).agentExited)
    }
}

/// A `ProcessInspector` over a fixed process table that counts its calls, so a
/// test can tell a cache hit from a fresh read.
private final class FakeProcessInspector: ProcessInspector {
    var processes: [pid_t: ProcessSnapshot]
    let shellNames: Set<String> = ["zsh", "bash"]
    private(set) var keyCalls = 0
    private(set) var snapshotCalls = 0
    private(set) var groupSizeCalls = 0

    init(_ snapshots: [ProcessSnapshot]) {
        processes = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
    }

    func key(of pid: pid_t) -> ProcessKey? {
        keyCalls += 1
        guard let process = processes[pid] else { return nil }
        return ProcessKey(pid: process.pid, comm: process.comm)
    }

    func snapshot(of pid: pid_t) -> ProcessSnapshot? {
        snapshotCalls += 1
        return processes[pid]
    }

    func groupSize(of pgid: pid_t) -> Int? {
        groupSizeCalls += 1
        return processes[pgid]?.groupSize
    }
}
