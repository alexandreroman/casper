import AppKit
import CasperCore
import Foundation

/// Detects and launches external code editors (VS Code, IntelliJ IDEA,
/// Xcode) for a workspace's worktree. Stateless — detection is cheap enough
/// (three short-lived shell processes) to call once at app startup and cache
/// the result on `AppModel`, rather than caching inside this type.
enum EditorLauncher {
    /// Editors whose CLI shim resolves on the user's `PATH` *and* whose app
    /// bundle resolves via a known bundle identifier. Both must hold — the
    /// icon lookup needs the bundle, and the launch needs the shim — so an
    /// editor with only one of the two is omitted rather than shown
    /// half-working. Preserves `EditorKind.priorityOrder`.
    static func detectInstalled() -> [EditorKind] {
        EditorKind.priorityOrder.filter { kind in
            resolveCLIPath(kind.cliCommand) != nil && resolveBundleURL(kind) != nil
        }
    }

    static func icon(for kind: EditorKind) -> NSImage? {
        resolveBundleURL(kind).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Launches `kind`'s CLI shim with `path` as its sole argument, run with
    /// `path` as the working directory. Throws on spawn failure (missing
    /// shim, permissions) so the caller can surface it.
    static func launch(_ kind: EditorKind, at path: String) throws {
        guard let cliPath = resolveCLIPath(kind.cliCommand) else {
            throw EditorLaunchError.shimNotFound(kind)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [path]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        try process.run()
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
    case shimNotFound(EditorKind)

    var errorDescription: String? {
        switch self {
        case .shimNotFound(let kind):
            "\(kind.displayName)'s `\(kind.cliCommand)` command is no longer on your PATH."
        }
    }
}
