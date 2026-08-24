import Foundation
import XCTest

@testable import CasperCore

/// Every test here drives `LoginShellPath` through its injected seams, so the
/// suite never spawns a real shell (which would source the developer's own
/// profile and make the results machine-dependent). The process `PATH` is
/// stubbed away for the same reason: resolution walks real directories with
/// `FileManager`, and the developer's own `PATH` must not decide a test.
final class LoginShellPathTests: XCTestCase {
    /// The probe seam is `@Sendable`, so a stub needs a `Sendable` place to
    /// record its calls — a lock-protected box, like `LoginShellPath`'s own
    /// storage.
    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var invocations: [[String]] = []

        var callCount: Int { lock.withLock { invocations.count } }
        var argumentLists: [[String]] { lock.withLock { invocations } }

        func record(_ arguments: [String]) {
            lock.withLock { invocations.append(arguments) }
        }
    }

    /// Directories created by `makeExecutable`, removed when the test ends.
    private var temporaryDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        LoginShellPath.resetForTesting()
        LoginShellPath.processSearchPath = { "" }
    }

    override func tearDown() {
        // The caches and the seams are process-wide, so hand them back clean.
        LoginShellPath.resetForTesting()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
        super.tearDown()
    }

    /// Installs a probe stub answering `output` for every candidate, and returns
    /// the recorder tracking how often (and with what) it was called.
    @discardableResult
    private func stubProbe(returning output: String?) -> ProbeRecorder {
        stubProbe { _ in output }
    }

    /// Installs a probe stub whose answer depends on the argument list, so a
    /// test can give each flag candidate a different `PATH`.
    @discardableResult
    private func stubProbe(_ answer: @escaping @Sendable ([String]) -> String?) -> ProbeRecorder {
        let recorder = ProbeRecorder()
        LoginShellPath.shellProbe = { arguments, _ in
            recorder.record(arguments)
            return answer(arguments)
        }
        return recorder
    }

    /// A fresh directory holding one real, executable file named `command`.
    ///
    /// Resolution asks `FileManager.isExecutableFile(atPath:)`, so the fixture
    /// has to be a real file with a real mode — an in-memory path would prove
    /// nothing.
    private func makeExecutable(named command: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginShellPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)

        let executable = directory.appendingPathComponent(command)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return directory.path
    }

    /// A fresh directory holding a *subdirectory* named `command` — the shape
    /// that `access(X_OK)` alone mistakes for an executable.
    private func makeDirectory(named command: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginShellPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(command, isDirectory: true), withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory.path
    }

    /// A command name no real machine can have on its `PATH`.
    private func uniqueCommandName() -> String {
        "casper-test-\(UUID().uuidString)"
    }

    // MARK: - The interactive candidate

    /// The bug this type exists to avoid: `-lc` never sources `.zshrc`, which is
    /// where the `PATH` a user actually has in a terminal is very commonly
    /// built. A command living only in a directory the *interactive* candidate
    /// reports must still resolve.
    func testResolvesACommandOnlyTheInteractiveCandidateReports() throws {
        let command = uniqueCommandName()
        let interactiveDirectory = try makeExecutable(named: command)
        stubProbe { arguments in
            arguments == LoginShellPath.interactiveLoginArguments ? interactiveDirectory : "/usr/bin"
        }

        XCTAssertEqual(LoginShellPath.resolve(command), "\(interactiveDirectory)/\(command)")
    }

    /// bash sources `~/.bashrc` only for an interactive **non-login** shell: an
    /// interactive *login* bash reads `~/.bash_profile` and stops there. So for
    /// a bash user the `-i -c` rung is the only one that sees the `PATH` built
    /// in `.bashrc`, and without it the interactive and login rungs answer
    /// exactly the same thing.
    func testResolvesACommandOnlyTheInteractiveNonLoginCandidateReports() throws {
        let command = uniqueCommandName()
        let bashrcDirectory = try makeExecutable(named: command)
        let recorder = stubProbe { arguments in
            arguments == LoginShellPath.interactiveArguments ? bashrcDirectory : "/usr/bin"
        }

        XCTAssertEqual(LoginShellPath.resolve(command), "\(bashrcDirectory)/\(command)")
        XCTAssertTrue(
            recorder.argumentLists.contains(LoginShellPath.interactiveArguments),
            "the interactive non-login rung is part of the union, not a fallback")
    }

    /// The other half of the union: whatever the login-only candidate reports —
    /// exactly what a `-lc` lookup saw — keeps resolving, even when an
    /// interactive `.zshrc` clobbers `PATH` instead of extending it.
    func testResolvesACommandOnlyTheLoginCandidateReports() throws {
        let command = uniqueCommandName()
        let loginDirectory = try makeExecutable(named: command)
        stubProbe { arguments in
            arguments == LoginShellPath.loginArguments ? loginDirectory : "/usr/bin"
        }

        XCTAssertEqual(LoginShellPath.resolve(command), "\(loginDirectory)/\(command)")
    }

    /// Both candidates report the command, in different directories. The
    /// interactive one is tried first, so its directory wins — that is what
    /// makes the user's terminal `PATH`, not the login-only subset, the answer.
    func testTheInteractiveCandidateIsTriedFirstAndItsAnswerWins() throws {
        let command = uniqueCommandName()
        let interactiveDirectory = try makeExecutable(named: command)
        let loginDirectory = try makeExecutable(named: command)
        let recorder = stubProbe { arguments in
            arguments == LoginShellPath.interactiveLoginArguments ? interactiveDirectory : loginDirectory
        }

        XCTAssertEqual(LoginShellPath.resolve(command), "\(interactiveDirectory)/\(command)")
        XCTAssertEqual(recorder.argumentLists.first, LoginShellPath.interactiveLoginArguments)
    }

    // MARK: - The csh fallback

    /// `csh` and `tcsh` reject `-l` outright, so a shell that answers neither
    /// login candidate gets one last chance without it.
    func testTheBareCandidateIsTriedWhenNeitherLoginCandidateAnswers() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: command)
        let recorder = stubProbe { arguments in
            arguments == LoginShellPath.plainArguments ? directory : nil
        }

        XCTAssertEqual(LoginShellPath.resolve(command), "\(directory)/\(command)")
        XCTAssertEqual(
            recorder.argumentLists,
            [
                LoginShellPath.interactiveLoginArguments,
                LoginShellPath.interactiveArguments,
                LoginShellPath.loginArguments,
                LoginShellPath.plainArguments,
            ])
    }

    /// For every shell that *did* answer, the bare candidate could only repeat
    /// what the login candidates already said, so it is not spawned at all.
    func testTheBareCandidateIsSkippedWhenALoginCandidateAnswered() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: command)
        let recorder = stubProbe { arguments in
            arguments == LoginShellPath.loginArguments ? directory : nil
        }

        XCTAssertNotNil(LoginShellPath.resolve(command))
        XCTAssertEqual(recorder.argumentLists, LoginShellPath.unionedArgumentCandidates)
    }

    // MARK: - Parsing what a shell actually prints

    /// A shell that sources a profile prints whatever the profile prints. The
    /// real `PATH` line has to survive the banners around it.
    func testANoisyProfileStillResolves() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: command)
        stubProbe(returning: """
            Homebrew shellenv applied
            nvm: now using node v22.3.0
            Welcome to this machine. Have a lot of fun!
            \(directory):/usr/bin:/bin
            Goodbye, see you soon.
            """)

        XCTAssertEqual(LoginShellPath.resolve(command), "\(directory)/\(command)")
    }

    /// Half of what makes the generous parse safe: a banner carrying no
    /// absolute path at all contributes no component, because only
    /// `/`-prefixed ones are kept. The other half — a banner that *does* name a
    /// real directory — is pinned by the two ordering tests below.
    func testBannerLinesWithoutAnAbsolutePathContributeNoSearchPathComponent() {
        let components = LoginShellPath.searchPathComponents(in: """
            Homebrew shellenv applied
            nvm: now using node v22.3.0
            Welcome to this machine. Have a lot of fun!
            /opt/homebrew/bin:/usr/bin
            Goodbye, see you soon.
            """)

        XCTAssertEqual(components, ["/opt/homebrew/bin", "/usr/bin"])
    }

    /// A profile prints its banners *before* `printenv` runs, so a directory
    /// picked up from one is seen first — and resolution takes the first
    /// directory that holds the command. The real `PATH` line is therefore
    /// emitted ahead of everything the other lines contributed, so noise can
    /// never outrank a genuine `PATH` entry. Nothing is dropped: the leftovers
    /// still follow, `https://docs.example.com`'s second half included.
    func testTheRealSearchPathLineIsOrderedAheadOfWhatBannersContribute() {
        let components = LoginShellPath.searchPathComponents(in: """
            mise WARN: /Users/alex/.local/share/mise/installs/node/20/bin
            Homebrew shellenv applied
            Docs: https://docs.example.com
            /opt/homebrew/bin:/usr/bin
            Goodbye, see you soon.
            """)

        XCTAssertEqual(
            components,
            [
                "/opt/homebrew/bin",
                "/usr/bin",
                "/Users/alex/.local/share/mise/installs/node/20/bin",
                "//docs.example.com",
            ])
    }

    /// The same rule where it actually bites: two directories hold the command,
    /// one named by a banner and one on the real `PATH`. The `PATH` wins — a
    /// banner deciding this would be a *wrong* answer, not merely a useless one.
    func testABannerDirectoryCannotOutrankTheRealSearchPath() throws {
        let command = uniqueCommandName()
        let bannerDirectory = try makeExecutable(named: command)
        let searchPathDirectory = try makeExecutable(named: command)
        stubProbe(returning: """
            mise WARN: \(bannerDirectory)
            \(searchPathDirectory):/usr/bin:/bin
            """)

        XCTAssertEqual(LoginShellPath.resolve(command), "\(searchPathDirectory)/\(command)")
    }

    // MARK: - What counts as an executable

    /// `FileManager.isExecutableFile(atPath:)` is `access(X_OK)`, which is true
    /// of any directory the user may search — so a search-path directory
    /// holding a *subdirectory* named like the command must not resolve to it.
    /// `Process.run()` would throw on that path, and `EditorLauncher` would have
    /// passed over its app-bundle fallback by then.
    func testADirectoryNamedLikeTheCommandDoesNotResolve() throws {
        let command = uniqueCommandName()
        let directory = try makeDirectory(named: command)
        stubProbe(returning: directory)

        XCTAssertNil(LoginShellPath.resolve(command))
    }

    /// The hazard that rules out `which`/`command -v`: an interactive shell also
    /// defines the user's functions, and a lookup would print the function body.
    /// Reading `PATH` cannot produce that, and even if such a blob reached the
    /// parser, nothing in it starts with `/`.
    func testAShellFunctionBodyResolvesToNothing() {
        stubProbe(returning: """
            codex () {
            \tcommand codex "$@"
            }
            """)

        XCTAssertNil(LoginShellPath.resolve("codex"))
    }

    func testTheSearchPathParseDropsEmptyAndRelativeComponents() {
        // A bare `::` means the working directory, which for a GUI app is `/` —
        // honouring it would resolve commands the user's terminal never would.
        let components = LoginShellPath.searchPathComponents(in: "/usr/bin::.:bin:/bin\n")

        XCTAssertEqual(components, ["/usr/bin", "/bin"])
    }

    func testTheSearchPathParseTrimsWhitespaceAndDeduplicates() {
        let components = LoginShellPath.searchPathComponents(in: "  /usr/bin : /bin \n/usr/bin\n")

        XCTAssertEqual(components, ["/usr/bin", "/bin"])
    }

    func testTheSearchPathParseOfNoOutputIsEmpty() {
        XCTAssertEqual(LoginShellPath.searchPathComponents(in: nil), [])
        XCTAssertEqual(LoginShellPath.searchPathComponents(in: "\n   \n\t\n"), [])
    }

    // MARK: - Caching

    /// The search path is probed once for the whole process, whatever the
    /// command: that is what keeps `EditorLauncher`'s main-actor lookup free.
    func testTheShellIsProbedOnceForTheWholeProcess() throws {
        let first = uniqueCommandName()
        let directory = try makeExecutable(named: first)
        let recorder = stubProbe(returning: directory)

        XCTAssertNotNil(LoginShellPath.resolve(first))
        let spawnsForTheFirstCommand = recorder.callCount
        XCTAssertEqual(recorder.argumentLists, LoginShellPath.unionedArgumentCandidates)

        XCTAssertNil(LoginShellPath.resolve(uniqueCommandName()))
        XCTAssertNil(LoginShellPath.resolve(uniqueCommandName()))

        XCTAssertEqual(recorder.callCount, spawnsForTheFirstCommand, "one probe answers every command name")
    }

    /// The answer is cached, not just the search path — a resolved command is
    /// never looked for on disk twice.
    func testAResolvedCommandIsCachedRatherThanSearchedAgain() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: command)
        stubProbe(returning: directory)
        let resolved = LoginShellPath.resolve(command)
        XCTAssertNotNil(resolved)

        try FileManager.default.removeItem(atPath: "\(directory)/\(command)")

        XCTAssertEqual(LoginShellPath.resolve(command), resolved)
    }

    /// A command that resolves to nothing paid the same probe cost as one that
    /// resolves, so the miss is cached like any other answer.
    func testCachesAFailedLookupToo() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: uniqueCommandName())
        stubProbe(returning: directory)

        XCTAssertNil(LoginShellPath.resolve(command))

        // Installing the command afterwards must not un-cache the miss.
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: "\(directory)/\(command)"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(directory)/\(command)")

        XCTAssertNil(LoginShellPath.resolve(command))
    }

    // MARK: - Timeout

    /// A profile that blocks (hung mount, `nvm`/`conda` waiting on the network)
    /// must not hold the caller forever: the work is abandoned on the deadline
    /// and the search path falls back to what the process itself has.
    func testWorkThatNeverAnswersIsAbandonedOnTheDeadline() {
        let release = DispatchSemaphore(value: 0)
        // Unblock the abandoned worker on the way out. It may still finish after
        // the test body returns — that is what "abandoned" means — but it is not
        // left parked on the semaphore for the rest of the run.
        defer { release.signal() }

        let components: [String]? = LoginShellPath.runWithTimeout(timeout: 0.05) {
            release.wait()  // stands in for a shell that never returns
            return ["/opt/homebrew/bin"]
        }

        XCTAssertNil(components)
    }

    func testWorkThatFinishesWithinTheDeadlineIsReturned() {
        let components: [String]? = LoginShellPath.runWithTimeout(timeout: 5) { ["/opt/homebrew/bin", "/usr/bin"] }

        XCTAssertEqual(components, ["/opt/homebrew/bin", "/usr/bin"])
    }

    /// The deadline is shared by the whole probe, not granted afresh to each
    /// rung: a first spawn that outlasts it must not buy the second one another
    /// `lookupTimeout`. Driven with a short deadline of its own rather than the
    /// real five seconds, which is the only thing the injected one stands in for.
    func testTheDeadlineBoundsTheWholeProbeRatherThanEachRung() {
        let recorder = ProbeRecorder()
        LoginShellPath.shellProbe = { arguments, deadline in
            recorder.record(arguments)
            // Stands in for a profile that outlasts the probe's deadline.
            while DispatchTime.now() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return "/opt/homebrew/bin"
        }

        LoginShellPath.shellSearchPath(into: LoginShellPath.ComponentsBox(), deadline: .now() + 0.2)

        XCTAssertEqual(
            recorder.argumentLists, [LoginShellPath.interactiveLoginArguments],
            "the rungs after the one that ate the deadline are skipped, not started")
    }

    /// A rung that answered before the deadline is kept even though the probe as
    /// a whole is abandoned. Otherwise a profile costing a few seconds per shell
    /// would resolve nothing at all: the first rung's good `PATH` would be
    /// thrown away with the second rung's, and the degraded result cached for
    /// the rest of the process's life.
    func testComponentsFoundBeforeTheDeadlineSurviveAnAbandonedProbe() {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        LoginShellPath.shellProbe = { arguments, _ in
            guard arguments != LoginShellPath.interactiveLoginArguments else { return "/opt/homebrew/bin" }
            release.wait()  // stands in for a rung that never answers
            return nil
        }

        let collected = LoginShellPath.ComponentsBox()
        let finished = LoginShellPath.runWithTimeout(timeout: 0.2) {
            LoginShellPath.shellSearchPath(into: collected, deadline: .now() + 5)
        }

        XCTAssertNil(finished, "the probe as a whole never completed")
        XCTAssertEqual(collected.components, ["/opt/homebrew/bin"], "the rung that did answer is not lost")
    }

    // MARK: - The process PATH fallback

    /// The process's own `PATH` is appended at the lowest priority, so a shell
    /// that answers nothing at all still leaves something to search.
    func testTheProcessSearchPathIsUsedWhenTheShellAnswersNothing() throws {
        let command = uniqueCommandName()
        let directory = try makeExecutable(named: command)
        LoginShellPath.processSearchPath = { directory }
        stubProbe(returning: nil)

        XCTAssertEqual(LoginShellPath.resolve(command), "\(directory)/\(command)")
    }
}
