import Foundation

/// Writes Casper's two built-in terminal themes to disk, where the conditional
/// `theme = light:…,dark:…` line in `GhosttyDefaultConfig` points.
///
/// They live for the app's whole lifetime, unlike the defaults file itself:
/// libghostty re-reads the selected theme file every time the colour scheme
/// changes, so a deleted file would leave the terminal without its colours at the
/// next system switch. Rewritten on every launch, so an updated Casper ships its
/// updated palette and the current system background colour, and again before every
/// colour-scheme switch (`GhosttyRuntime.setColorScheme`), which heals files a cache
/// cleaner purged meanwhile. Concurrent sessions write identical bytes.
enum GhosttyThemeFiles {
    struct Paths: Equatable {
        let light: URL
        let dark: URL
    }

    /// `~/Library/Caches/<bundle id>/ghostty-themes`, or `…/casper/…` for an
    /// unbundled binary.
    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "casper")
            .appendingPathComponent("ghostty-themes")
    }

    static func write(to directory: URL) throws -> Paths {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = Paths(
            light: directory.appendingPathComponent("casper-light"),
            dark: directory.appendingPathComponent("casper-dark"))
        let light = GhosttyDefaultConfig.lightTheme(background: GhosttyDefaultConfig.contentBackgroundHex(for: .aqua))
        let dark = GhosttyDefaultConfig.darkTheme(background: GhosttyDefaultConfig.contentBackgroundHex(for: .darkAqua))
        try light.write(to: paths.light, atomically: true, encoding: .utf8)
        try dark.write(to: paths.dark, atomically: true, encoding: .utf8)
        return paths
    }
}
