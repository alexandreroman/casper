import Foundation

/// Resolves a command name to its absolute path against the user's **login
/// shell** `PATH`, not the current process's `PATH`.
///
/// Casper is launched from Finder/Dock, so its own environment lacks the
/// shell-profile `PATH` additions (Homebrew, `nvm`, JetBrains Toolbox shims,
/// etc.) where commands like `code`, `idea` or `xed` commonly live. Asking a
/// login shell is the only reliable way to see the `PATH` the user sees in a
/// terminal.
///
/// A lookup spawns `$SHELL -lc 'which <command>'`, which sources the user's
/// profile — routinely hundreds of milliseconds of blocked caller. Neither the
/// `PATH` nor the answer can change during a session, so the result (including a
/// failure) is cached after the first completed lookup and every later caller is
/// served from the cache. The check and the store are separate steps, so two
/// callers racing on a cold cache do both spawn a shell; that is harmless —
/// the lookup is idempotent and they agree on the answer — and cheaper than
/// holding the lock across a process spawn.
///
/// Concurrency (Swift 6): the cache and the runner seam are process-wide mutable
/// state reachable from any isolation domain, so they live in a lock-protected
/// `Storage` box rather than in `nonisolated(unsafe)` globals — the
/// `@unchecked Sendable` + documented-discipline idiom `SessionStore` and the
/// socket types already use. The lock is never held across the shell spawn.
public enum LoginShellPath {
    private static let storage = Storage()

    /// The absolute path `command` resolves to, or `nil` when the login shell
    /// cannot find it. Blocking on the first call for a given command, cached
    /// afterwards — a missing command is the case that pays the full
    /// login-shell cost, so it is the one that most needs remembering.
    public static func resolve(_ command: String) -> String? {
        if let cached = storage.cachedPath(for: command) { return cached }
        let resolved = lastNonEmptyLine(of: storage.runner(command))
        storage.cachePath(resolved, for: command)
        return resolved
    }

    #if DEBUG
        /// The step that actually runs the shell, injectable so tests never spawn
        /// one. Takes a command name and returns the raw stdout of the lookup, or
        /// `nil` when it failed.
        ///
        /// `#if DEBUG` on purpose: this is a test seam, and a shipping build must
        /// not carry a way to swap the process-wide shell runner. Tests build
        /// debug, so `@testable import CasperCore` still sees it.
        static var runner: @Sendable (String) -> String? {
            get { storage.runner }
            set { storage.runner = newValue }
        }

        /// Drops every cached lookup and restores the real, shell-spawning runner,
        /// so one test's stub and its results never leak into the next.
        static func resetForTesting() {
            storage.reset()
        }
    #endif

    /// A login shell (`-lc`) sources `~/.zprofile`/`~/.zlogin`, which may print
    /// banner/status text (Homebrew shellenv, nvm/pyenv/conda, direnv, MOTD
    /// hooks) to stdout at startup — before `which` ever runs. The resolved path
    /// is therefore the last non-empty line, not the whole blob.
    private static func lastNonEmptyLine(of output: String?) -> String? {
        output?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// Runs `$SHELL -lc 'which <command>'` and returns its raw stdout,
    /// discarding stderr; `nil` on a spawn failure or a non-zero exit.
    /// Blocking and expensive — only ever reached through `resolve`'s cache.
    private static func runLoginShellWhich(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "which \(command)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    /// `@unchecked Sendable`: both mutable fields are only ever touched under
    /// `lock`, and the box holds nothing else.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var resolvedPaths: [String: String?] = [:]
        private var shellRunner: @Sendable (String) -> String? = LoginShellPath.runLoginShellWhich

        var runner: @Sendable (String) -> String? {
            get { lock.withLock { shellRunner } }
            set { lock.withLock { shellRunner = newValue } }
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
                shellRunner = LoginShellPath.runLoginShellWhich
            }
        }
    }
}
