import AppKit
import CasperCore
import Foundation

/// Detects and launches external code editors (VS Code, IntelliJ IDEA,
/// Xcode) for a workspace's worktree. `detectInstalled()` is cheap enough (it
/// only resolves app bundle identifiers, spawning no processes) to call once at
/// app startup and cache the result on `AppModel`.
///
/// The two expensive lookups are memoized here instead, because their callers
/// cannot afford to hit the system: `icon(for:)` runs on every
/// `WorkspaceDetailView` body pass (once per editor menu entry, and a `Menu`'s
/// content is built eagerly), and `resolveCLIPath` spawns a **login** shell,
/// which sources the user's profile — routinely hundreds of milliseconds of
/// blocked main thread. Neither result can change during a session, so both are
/// resolved at most once. Main-actor-isolated for that shared state; every
/// caller is already on the main actor.
@MainActor
enum EditorLauncher {
    private static var iconCache: [EditorKind: NSImage] = [:]
    /// Keyed by CLI command. The value is optional so a command that resolves to
    /// nothing is cached too — a missing shim is the case that pays the full
    /// login-shell cost, so it is the one that most needs remembering.
    private static var cliPathCache: [String: String?] = [:]

    /// Editors whose app bundle resolves via a known bundle identifier. The
    /// CLI shim is *not* required: some editors (IntelliJ IDEA) don't
    /// auto-install theirs, leaving it missing on most users' `PATH` even
    /// though the editor itself is installed. `launch(_:at:)` falls back to
    /// opening the bundle directly when the shim is absent, so bundle
    /// resolution alone is enough to guarantee a working launch.
    /// Preserves `EditorKind.priorityOrder`.
    static func detectInstalled() -> [EditorKind] {
        EditorKind.priorityOrder.filter { kind in
            resolveBundleURL(kind) != nil
        }
    }

    static func icon(for kind: EditorKind) -> NSImage? {
        if let cached = iconCache[kind] { return cached }
        guard let bundleURL = resolveBundleURL(kind) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        iconCache[kind] = icon
        return icon
    }

    /// Launches `kind` for `path`, preferring its CLI shim when one resolves:
    /// spawning it via `Process` is faster and reuses an already-open window
    /// better than a bundle open does. When the shim isn't found (e.g.
    /// IntelliJ IDEA's `idea` shim, which isn't installed automatically),
    /// falls back to opening `kind`'s app bundle via
    /// `NSWorkspace.shared.open(_:withApplicationAt:configuration:completionHandler:)`.
    /// That fallback is fire-and-forget: its completion handler runs
    /// asynchronously, so a failure there is logged rather than thrown. This
    /// function only throws when neither mechanism resolves at all, which
    /// should be rare now that `detectInstalled()` requires the bundle.
    static func launch(_ kind: EditorKind, at path: String) throws {
        if let cliPath = resolveCLIPath(kind.cliCommand) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [path]
            process.currentDirectoryURL = URL(fileURLWithPath: path)
            try process.run()
            return
        }
        guard let bundleURL = resolveBundleURL(kind) else {
            throw EditorLaunchError.notFound(kind)
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: bundleURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if let error {
                CasperLog.app.failure("failed to open \(kind.displayName) via bundle", error)
            }
        }
    }

    private static func resolveBundleURL(_ kind: EditorKind) -> URL? {
        kind.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Resolves `command` against the user's **login shell** `PATH`, not
    /// Casper's own process `PATH` — Casper is launched from Finder/Dock, so
    /// its environment lacks shell-profile `PATH` additions (Homebrew, `nvm`,
    /// JetBrains Toolbox shims, etc.) where `code`/`idea`/`xed` commonly live.
    /// Runs `$SHELL -lc 'which <command>'`, discarding stderr, and returns the
    /// last non-empty line of stdout (profile banners print before `which`, so
    /// the resolved path is last); `nil` on a non-zero exit or empty output.
    private static func resolveCLIPath(_ command: String) -> String? {
        if let cached = cliPathCache[command] { return cached }
        let resolved = runWhich(command)
        cliPathCache[command] = resolved
        return resolved
    }

    /// Runs `$SHELL -lc 'which <command>'` and returns the resolved path, or `nil`.
    /// Blocking and expensive — only ever called through `resolveCLIPath`'s cache.
    private static func runWhich(_ command: String) -> String? {
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
            // A login shell (`-lc`) sources `~/.zprofile`/`~/.zlogin`, which may
            // print banner/status text (Homebrew shellenv, nvm/pyenv/conda,
            // direnv, MOTD hooks) to stdout at startup — before `which` runs.
            // The resolved path is therefore the last non-empty line, not the
            // whole blob.
            let resolvedPath = String(decoding: data, as: UTF8.self)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            return resolvedPath
        } catch {
            return nil
        }
    }
}

enum EditorLaunchError: LocalizedError {
    case notFound(EditorKind)

    var errorDescription: String? {
        switch self {
        case .notFound(let kind):
            "\(kind.displayName) could not be launched — its command-line launcher and app " +
                "bundle were both unavailable. It may have been uninstalled."
        }
    }
}
