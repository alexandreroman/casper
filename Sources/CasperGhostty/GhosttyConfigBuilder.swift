import CasperCore
import Foundation
import GhosttyKit

/// Builds the finalized libghostty config: Casper's built-in defaults, then the
/// user's own files, with a fallback to Casper's themes when the user's `theme`
/// cannot be loaded.
///
/// The fallback exists because a later `theme = …` replaces Casper's conditional
/// theme outright, yet a *named* theme (`theme = Arthur`, as Ghostty's app writes
/// into `?auto/theme.ghostty`) only resolves from `~/.config/ghostty/themes/` or
/// Ghostty's resources dir, which Casper does not have. The load then fails and the
/// terminal would render libghostty's vanilla colours with no light/dark switching.
enum GhosttyConfigBuilder {
    /// Returns a finalized config the caller owns (free it with `ghostty_config_free`),
    /// or nil if libghostty cannot allocate one.
    ///
    /// `loadUserFiles` loads the user's config; it is a closure so tests can stand in
    /// for the user's real files. If the result carries a theme-load diagnostic and
    /// `themes` is available, the config is built a second time with Casper's `theme`
    /// line loaded after the user's files. Without `themes` there is nothing to fall
    /// back to, so the first config is kept.
    static func makeConfig(
        themes: GhosttyThemeFiles.Paths?,
        loadUserFiles: (ghostty_config_t) -> Void
    ) -> ghostty_config_t? {
        guard let config = build(themes: themes, forceThemes: false, loadUserFiles: loadUserFiles) else {
            return nil
        }
        guard let themes, let failure = firstThemeLoadFailure(in: config) else { return config }

        CasperLog.ghostty.warning("""
            a Ghostty theme could not be loaded; \
            using Casper's built-in light and dark themes (\(failure))
            """)
        ghostty_config_free(config)
        // If the rebuild cannot allocate, nil is the honest answer: the caller's error path handles it.
        return build(themes: themes, forceThemes: true, loadUserFiles: loadUserFiles)
    }

    private static func build(
        themes: GhosttyThemeFiles.Paths?,
        forceThemes: Bool,
        loadUserFiles: (ghostty_config_t) -> Void
    ) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        // Casper's defaults go first so any user setting still wins.
        loadText(GhosttyDefaultConfig.text(themes: themes), named: "default-config", into: config)
        loadUserFiles(config)
        if forceThemes, let themes {
            // Loaded after the user's files so Casper's conditional theme replaces the broken one.
            loadText(GhosttyDefaultConfig.themeLine(themes) + "\n", named: "theme-override", into: config)
        }
        ghostty_config_finalize(config)
        return config
    }

    private static func firstThemeLoadFailure(in config: ghostty_config_t) -> String? {
        for index in 0..<ghostty_config_diagnostics_count(config) {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            guard let message = diagnostic.message.map({ String(cString: $0) }) else { continue }
            if GhosttyDefaultConfig.isThemeLoadFailure(message) { return message }
        }
        return nil
    }

    /// libghostty exposes no load-from-string API — only `ghostty_config_load_file` — so
    /// `text` is written to a per-process temp file, loaded, then removed. Never crashes:
    /// if the file can't be written the text is skipped and the terminal still starts.
    private static func loadText(_ text: String, named name: String, into config: ghostty_config_t) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-\(name)-\(ProcessInfo.processInfo.processIdentifier).ghostty")
        do {
            try text.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            CasperLog.ghostty.warning("failed to write \(name) config; skipping: \(error)")
            return
        }
        // Remove the temp file once loaded; a cleanup failure is harmless, so ignore it.
        defer { try? FileManager.default.removeItem(at: path) }
        ghostty_config_load_file(config, path.path)
    }
}
