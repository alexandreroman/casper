import AppKit
import CasperCore
import Foundation

/// Detects and launches external code editors (VS Code, IntelliJ IDEA,
/// Xcode) for a workspace's worktree. `detectInstalled()` is cheap enough (it
/// only resolves app bundle identifiers, spawning no processes) to call once at
/// app startup and cache the result on `AppModel`.
///
/// `icon(for:)` is memoized here because its caller cannot afford to hit the
/// system: it runs on every `WorkspaceDetailView` body pass (once per editor
/// menu entry, and a `Menu`'s content is built eagerly), and the icon cannot
/// change during a session. Main-actor-isolated for that shared state; every
/// caller is already on the main actor. The other expensive lookup — resolving
/// an editor's CLI shim against the user's login-shell `PATH` — is memoized by
/// `LoginShellPath` in CasperCore, which is shared with its non-UI callers.
@MainActor
enum EditorLauncher {
    private static var iconCache: [EditorKind: NSImage] = [:]

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
        if let cliPath = LoginShellPath.resolve(kind.cliCommand) {
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
