import Foundation

/// Resolves a command name to its absolute path against the `PATH` the user has
/// **in a terminal**, not the bare `PATH` a Finder/Dock-launched app inherits
/// from launchd.
///
/// Casper is launched from Finder or the Dock, so its own environment lacks the
/// shell-profile `PATH` additions (Homebrew, `nvm`, JetBrains Toolbox shims,
/// `~/.local/bin`) where commands like `code`, `idea`, `claude` or `codex`
/// commonly live.
///
/// ### Why the shell is asked for `PATH`, not for the command
///
/// A *non-interactive* login shell (`$SHELL -lc …`) sources `.zshenv`,
/// `.zprofile` and `.zlogin` but never `.zshrc` — zsh reserves that file for
/// interactive shells, and bash draws its own line between `.bash_profile` and
/// `.bashrc`. The `PATH` a user actually has is very commonly built in one of
/// those rc files, so a login-only shell cannot see it. That gap is the bug this
/// type exists to avoid.
///
/// An *interactive* shell does source the rc file — and with it the user's
/// aliases and functions, which `which` and `command -v` report as readily as
/// real files. A `.zshrc` that defines a `codex` shell function makes
/// `zsh -ilc 'which codex'` print a multi-line function body and
/// `zsh -ilc 'command -v codex'` print the bare word `codex`; neither is a
/// path, and either would be worse than answering nothing. So Casper never asks
/// a shell to resolve a command. It asks for the `PATH`, then searches that
/// `PATH` itself, with the filesystem as the only arbiter of what exists.
///
/// ### The probe
///
/// The probe body is the single command `/usr/bin/printenv PATH`: an absolute
/// external binary with no shell syntax in it, so it is dialect-independent —
/// it works whatever `$SHELL` is (fish, whose `$PATH` is a list, nu, csh, ksh)
/// because `PATH` is exported to every child. Only the *flags* are
/// dialect-specific, and three sets are unioned, in the order they are tried:
///
/// - `-i -l -c` — interactive **and** login. This is the rung that reaches
///   zsh's `.zshrc`; bash on this rung reads `.bash_profile` and stops.
/// - `-i -c` — interactive, **not** login. This is the rung that reaches bash's
///   `.bashrc`, which bash sources only for an interactive non-login shell, so
///   for a bash user it is the decisive one. zsh sources `.zshrc` here too, so
///   it costs one spawn and changes nothing for zsh users.
/// - `-l -c` — login only. Misses both rc files, but every shell accepts it.
///
/// Unioning the three means no rung's answer can be *shrunk* by another: a
/// `.zshrc` that clobbers `PATH` instead of extending it can only ever add
/// directories. `-c` alone is the last resort, reached only when all three
/// produced nothing, and recovers `/bin/csh` and `/bin/tcsh`, which reject `-l`
/// outright. The process's own `PATH` is appended last.
///
/// `-i` is not free of side effects: an rc file is entitled to do things a
/// profile is not. An `exec tmux` or `exec fish` guarded on `$TMUX` is a common
/// `.bashrc`/`.zshrc` line, and when it fires `printenv` never runs and the rung
/// silently contributes nothing — recoverable through the other rungs, but not
/// what "only the flags are dialect-specific" would lead you to expect.
/// Interactive zsh also opens `$HISTFILE`.
///
/// A flag set an exotic shell dislikes comes back as a non-zero exit, and a
/// `$SHELL` naming a shell that is not installed makes the spawn itself throw.
/// Either way that rung answers nothing, the next one runs, and a shell that
/// refuses all of them still leaves the process `PATH` to search.
///
/// Every spawn reads stdin from `/dev/null`. A profile that reads from stdin (a
/// `read` confirmation, a version-manager prompt) blocks forever when the child
/// inherits the app's own input, and finishes instantly on EOF.
///
/// ### Cost
///
/// One probe per process — up to three spawns, ~0.5 s — shared by every command
/// name, with `lookupTimeout` bounding the probe as a whole rather than each
/// spawn. Every `resolve` after it, `EditorLauncher`'s main-actor one included,
/// is a handful of `stat` calls against the cached components and spawns
/// nothing. Answers are cached per command, misses included, since neither the
/// `PATH` nor the answer can change during a session. The cache check and the
/// store are separate steps, so two callers racing on a cold cache can both
/// probe; that is harmless — the probe is idempotent and they agree on the
/// answer — and cheaper than holding the lock across a process spawn.
///
/// Concurrency (Swift 6): the caches and the test seams are process-wide
/// mutable state reachable from any isolation domain, so they live in a
/// lock-protected `Storage` box rather than in `nonisolated(unsafe)` globals —
/// the `@unchecked Sendable` + documented-discipline idiom `SessionStore` and
/// the socket types already use. The lock is never held across a shell spawn.
public enum LoginShellPath {
    private static let storage = Storage()

    /// The absolute path `command` resolves to, or `nil` when it is on none of
    /// the search path's directories. Blocking on the very first call of the
    /// process (the one that pays for the `PATH` probe), cached afterwards —
    /// a missing command is cached like any other answer, since it costs
    /// exactly as much to establish.
    public static func resolve(_ command: String) -> String? {
        if let cached = storage.cachedPath(for: command) { return cached }
        let resolved = firstExecutable(named: command, in: searchPath())
        storage.cachePath(resolved, for: command)
        return resolved
    }

    /// How long the whole `PATH` probe may take before Casper gives up on it.
    ///
    /// `printenv` itself is instant; the cost is the shell sourcing the user's
    /// profile. A profile that *blocks* — a hung network mount, an `nvm` or
    /// `conda` bootstrap waiting on the network — would otherwise block its
    /// caller forever. A populated profile costs ~0.5 s on this machine, but a
    /// far heavier one — a networked home directory, a `conda`/`mise`
    /// bootstrap — can legitimately take seconds, so the bound is set at five:
    /// generous enough not to cut such a profile short, and still well below
    /// anyone's patience.
    static let lookupTimeout: TimeInterval = 5

    /// The one command handed to `$SHELL`. Absolute and free of shell syntax on
    /// purpose, so no dialect can misread it — see the type's documentation.
    static let pathProbeCommand = "/usr/bin/printenv PATH"

    /// Interactive **and** login: the rung that sources zsh's `.zshrc`. bash on
    /// this rung reads `.bash_profile` and never `.bashrc`.
    static let interactiveLoginArguments = ["-i", "-l", "-c", pathProbeCommand]

    /// Interactive, **not** login: the only rung that sources bash's `.bashrc`,
    /// which bash reserves for interactive non-login shells. zsh sources
    /// `.zshrc` here as well.
    static let interactiveArguments = ["-i", "-c", pathProbeCommand]

    /// Login only. Misses both rc files, but every shell accepts it and it can
    /// only add to what the interactive rungs answered.
    static let loginArguments = ["-l", "-c", pathProbeCommand]

    /// Neither login nor interactive — the last resort for `csh`/`tcsh`, which
    /// reject `-l` outright and would otherwise contribute nothing at all.
    static let plainArguments = ["-c", pathProbeCommand]

    /// The rungs whose answers are unioned, in the order they are tried.
    /// Internal rather than private so tests can pin that order.
    ///
    /// Flags are passed as separate arguments rather than clustered (`-ilc`):
    /// verified to work on zsh, bash, dash, ksh and sh, and likelier to be
    /// understood by a shell that does not parse its flags with getopt.
    static let unionedArgumentCandidates = [interactiveLoginArguments, interactiveArguments, loginArguments]

    /// The directories `resolve` searches, computed once per process: what the
    /// shell reports, then the process's own `PATH` at the lowest priority.
    ///
    /// `lookupTimeout` bounds the probe as a whole. Each rung publishes into
    /// `collected` as it finishes, so a rung that answered before the deadline
    /// survives the probe being abandoned — only work still in flight is lost.
    ///
    /// The result is then cached **whether or not the probe completed, for the
    /// rest of the process's life**: an abandoned probe leaves this process with
    /// the bare launchd `PATH` until Casper is relaunched, and no later call
    /// retries. That is deliberate rather than accidental — re-probing would
    /// spawn shells again on every `AgentIntegrationProbe` tick, and a profile
    /// that blocks once blocks every time.
    private static func searchPath() -> [String] {
        if let cached = storage.cachedSearchPath { return cached }
        let collected = ComponentsBox()
        // Monotonic, and the same instant the waiting semaphore below is armed
        // against: a wall-clock deadline would jump hours across a system sleep,
        // skipping every rung while the real budget had barely moved.
        let deadline = DispatchTime.now() + lookupTimeout
        let fromShell =
            runWithTimeout(timeout: lookupTimeout) {
                shellSearchPath(into: collected, deadline: deadline)
            } ?? collected.components
        let components = deduplicated(fromShell + searchPathComponents(in: storage.processSearchPath()))
        storage.cacheSearchPath(components)
        return components
    }

    /// Unions what the flag rungs report, in the order they are tried,
    /// publishing each rung's components into `collected` as they arrive.
    ///
    /// A rung whose turn comes after `deadline` has passed is skipped rather
    /// than started: the whole point of the shared deadline is that a wedged
    /// first spawn cannot buy the second one another `lookupTimeout`. The same
    /// deadline is handed to each spawn, which arms its terminate-watchdog on
    /// it.
    ///
    /// Internal rather than private so tests can drive the shared deadline
    /// directly instead of waiting out a real `lookupTimeout`.
    @discardableResult
    static func shellSearchPath(into collected: ComponentsBox, deadline: DispatchTime) -> [String] {
        let probe = storage.shellProbe
        for arguments in unionedArgumentCandidates where DispatchTime.now() < deadline {
            collected.append(searchPathComponents(in: probe(arguments, deadline)))
        }
        // Only a shell that understood none of the rungs above gets this one; for
        // every other shell it would just repeat what they already said.
        if collected.components.isEmpty, DispatchTime.now() < deadline {
            collected.append(searchPathComponents(in: probe(plainArguments, deadline)))
        }
        return collected.components
    }

    /// The `/`-prefixed directories in a probe's raw stdout, deduplicated, with
    /// the ones that came from a real `PATH` line first.
    ///
    /// The parse is deliberately generous — every line is split on `:`, not just
    /// the one that looks like a `PATH` — because a shell that sources a profile
    /// prints whatever that profile prints: Homebrew shellenv notices, a MOTD, a
    /// `.zlogout` farewell. Being generous is safe only because of the order
    /// below: resolution takes the *first* directory holding the command, and a
    /// profile prints its banners **before** `printenv` runs, so a banner
    /// naming a real directory would otherwise outrank the whole real `PATH` and
    /// decide the answer whenever two directories hold the same command.
    ///
    /// So the real `PATH` line — the last non-empty line whose `:`-separated
    /// components are *all* absolute — is emitted first, and the `/`-prefixed
    /// leftovers of every other line follow it. Nothing is dropped, and nothing
    /// picked up from a banner can outrank a genuine `PATH` entry. Some of those
    /// leftovers are not directories at all: `https://docs.example.com` in a
    /// MOTD splits into `https` and `//docs.example.com`, and the second half
    /// passes a bare `/`-prefix test. Harmless, since resolution then asks the
    /// filesystem — but it shows how much noise reaches the list.
    ///
    /// Empty and relative components are dropped. An empty component in a `PATH`
    /// means the working directory, and a GUI app's working directory is `/`, so
    /// honouring it would resolve commands the user's terminal never would.
    ///
    /// Internal rather than private so tests can pin the parse on its own.
    static func searchPathComponents(in output: String?) -> [String] {
        guard let output else { return [] }
        let lines = output.components(separatedBy: .newlines)
        let searchPathLine = lines.lastIndex(where: isSearchPathLine)

        var ordered = searchPathLine.map { directories(in: lines[$0]) } ?? []
        for (index, line) in lines.enumerated() where index != searchPathLine {
            ordered += directories(in: line)
        }
        return deduplicated(ordered)
    }

    /// Whether `line` reads as a `PATH` value rather than as profile output:
    /// every one of its `:`-separated components is an absolute path.
    private static func isSearchPathLine(_ line: String) -> Bool {
        components(of: line).allSatisfy { $0.hasPrefix("/") }
    }

    /// The absolute directories named on one line of probe output.
    private static func directories(in line: String) -> [String] {
        components(of: line).filter { $0.hasPrefix("/") }
    }

    private static func components(of line: String) -> [String] {
        line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// First directory of the search path holding an executable named `command`.
    private static func firstExecutable(named command: String, in directories: [String]) -> String? {
        for directory in directories {
            let candidate = "\(directory)/\(command)"
            if isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Whether `path` is something Casper could actually run.
    ///
    /// `FileManager.isExecutableFile(atPath:)` on its own is `access(X_OK)`,
    /// which is true of **any directory** the user may search — so a search-path
    /// directory holding a *subdirectory* named like the command would otherwise
    /// resolve to that directory. `Process.run()` then throws on it, and for
    /// `EditorLauncher` that throw comes too late: the CLI branch has already
    /// been taken, so the app-bundle fallback below it is never reached.
    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func deduplicated(_ components: [String]) -> [String] {
        var seen: Set<String> = []
        return components.filter { seen.insert($0).inserted }
    }

    /// Runs `work` on a background thread and waits at most `timeout` for it,
    /// answering nil when the deadline passes. `searchPath` then keeps whatever
    /// the finished rungs published and falls back to the process `PATH`, which
    /// is the point: without a bound, one wedged profile blocks its caller — the
    /// main actor, for `EditorLauncher.launch` — and leaves
    /// `AgentIntegrationProbe`'s task unfinished for the rest of the session.
    ///
    /// The abandoned thread is left to finish on its own. `runShellProbe`
    /// terminates its shell on the same deadline, so it normally unblocks
    /// moments later; this outer bound covers the case where it cannot, since a
    /// process stuck in an uninterruptible read ignores `SIGTERM`.
    ///
    /// Internal rather than private so tests can drive the deadline through the
    /// injected probe instead of waiting on a real shell.
    static func runWithTimeout<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T?) -> T? {
        let result = ResultBox<T>()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.value = work()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.value
    }

    #if DEBUG
        /// The step that actually runs the shell, injectable so tests never spawn
        /// one. Takes the argument list handed to `$SHELL` — which lets a test
        /// pin the rung order — and the probe's shared deadline, and returns the
        /// raw stdout, or `nil` when the shell failed to start or exited
        /// non-zero.
        ///
        /// `#if DEBUG` on purpose: this is a test seam, and a shipping build must
        /// not carry a way to swap the process-wide shell probe. Tests build
        /// debug, so `@testable import CasperCore` still sees it.
        static var shellProbe: @Sendable ([String], DispatchTime) -> String? {
            get { storage.shellProbe }
            set { storage.shellProbe = newValue }
        }

        /// The process's own `PATH`, injectable for the same reason: a test that
        /// asserts a command resolves *nowhere* must not see the developer's real
        /// `PATH`.
        static var processSearchPath: @Sendable () -> String {
            get { storage.processSearchPath }
            set { storage.processSearchPath = newValue }
        }

        /// Drops both caches — the per-command answers and the search path — and
        /// restores the real, shell-spawning seams, so one test's stubs and its
        /// results never leak into the next.
        static func resetForTesting() {
            storage.reset()
        }
    #endif

    /// Runs `$SHELL` with `arguments` and returns its raw stdout, discarding
    /// stderr; `nil` on a spawn failure or a non-zero exit. Blocking and
    /// expensive — only ever reached through `searchPath`'s cache.
    ///
    /// `deadline` is the probe's shared deadline, not this spawn's own: passing
    /// it in rather than reading it from shared state is what keeps two callers
    /// racing on a cold cache from arming each other's watchdogs.
    private static func runShellProbe(_ arguments: [String], deadline: DispatchTime) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        // An interactive shell with no tty is noisy — zsh alone emits "can't change
        // option: monitor" and any gitstatus/version-manager warnings the profile
        // triggers. None of it is ours to show.
        process.standardError = FileHandle.nullDevice
        // Load-bearing: a profile that reads from stdin blocks forever if the child
        // inherits the app's input. Against /dev/null the read gets EOF at once.
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // `readDataToEndOfFile()` waits for the write end of the pipe to close, which
        // only happens once the shell and everything it spawned have exited — so a
        // profile that blocks holds this thread indefinitely. Terminating the shell on
        // the probe's deadline closes the pipe and unblocks the read. Best effort by
        // design: `runWithTimeout` bounds the caller whether or not this lands.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func liveProcessSearchPath() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? ""
    }

    /// Collects search-path components as each probe rung answers, so that the
    /// rungs which finished before the deadline outlive a probe that as a whole
    /// is abandoned — `runWithTimeout` is all-or-nothing, and without this a
    /// timeout would discard a perfectly good first answer.
    ///
    /// `@unchecked Sendable`: the single field is only ever touched under `lock`.
    /// Internal rather than private so tests can hold one across a timeout.
    final class ComponentsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        var components: [String] { lock.withLock { stored } }

        func append(_ components: [String]) {
            lock.withLock { stored += components }
        }
    }

    /// Carries a background thread's answer back to the waiting caller.
    /// `@unchecked Sendable`: the single field is only ever touched under `lock`.
    private final class ResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?

        var value: T? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// `@unchecked Sendable`: every mutable field is only ever touched under
    /// `lock`, and the box holds nothing else.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var resolvedPaths: [String: String?] = [:]
        private var searchPath: [String]?
        private var probe: @Sendable ([String], DispatchTime) -> String? = LoginShellPath.runShellProbe
        private var processPath: @Sendable () -> String = LoginShellPath.liveProcessSearchPath

        var shellProbe: @Sendable ([String], DispatchTime) -> String? {
            get { lock.withLock { probe } }
            set { lock.withLock { probe = newValue } }
        }

        var processSearchPath: @Sendable () -> String {
            get { lock.withLock { processPath } }
            set { lock.withLock { processPath = newValue } }
        }

        var cachedSearchPath: [String]? {
            lock.withLock { searchPath }
        }

        func cacheSearchPath(_ components: [String]) {
            lock.withLock { searchPath = components }
        }

        /// The doubly-optional result separates "never looked up" (outer `nil`)
        /// from "looked up and not found" (inner `nil`), which is what keeps an
        /// unresolvable command cached instead of retried.
        func cachedPath(for command: String) -> String?? {
            lock.withLock { resolvedPaths[command] }
        }

        func cachePath(_ path: String?, for command: String) {
            lock.withLock { resolvedPaths[command] = path }
        }

        func reset() {
            lock.withLock {
                resolvedPaths.removeAll()
                searchPath = nil
                probe = LoginShellPath.runShellProbe
                processPath = LoginShellPath.liveProcessSearchPath
            }
        }
    }
}
