/// Casper's built-in libghostty defaults, baked into the binary and loaded
/// *before* the user's own Ghostty config so any user setting still overrides
/// them: the terminal colours and the clipboard-write policy.
///
/// The colours ship as two Ghostty themes, "Arthur" (dark) and "GitHub Light",
/// written to disk by `GhosttyThemeFiles` and selected by one conditional
/// `theme = light:<path>,dark:<path>` line, so the terminal follows the system
/// appearance. They are themes rather than explicit `background = …` keys
/// because in Ghostty an explicit colour key beats any theme, whichever file set
/// it: explicit defaults would mask a `theme` in the user's own config. As themes,
/// they lose to every explicit user key, and a user's own `theme` replaces
/// Casper's value outright.
///
/// The defaults are embedded because, on macOS, libghostty resolves the user's
/// config directory from the running app's bundle identifier
/// (`~/Library/Application Support/<CFBundleIdentifier>/`). A bundled `Casper.app`
/// is keyed on `com.github.alexandreroman.casper`, whose config dir is empty, so without
/// these embedded defaults the bundle would render libghostty's vanilla `#282c34`
/// gray instead of the theme the dev build shows. The theme bodies are inlined here
/// (no `themes/` dir or `GHOSTTY_RESOURCES_DIR` needed), keeping them self-contained.
///
/// `clipboard-write` is set to `ask` because libghostty's own default is `allow`,
/// under which `write_clipboard_cb` is always flagged trusted and
/// `GhosttyClipboardWrite.apply`'s untrusted branch is unreachable. `ask` makes
/// libghostty raise the `confirm` flag instead, which keeps
/// `GhosttyClipboardWrite.approveUntrusted` the single place the write policy is
/// decided rather than dead code. A user who prefers the upstream behaviour can
/// override it with `clipboard-write = allow`.
enum GhosttyDefaultConfig {
    /// The "Arthur" theme, in Ghostty theme-file syntax.
    static let darkTheme = """
        palette = 0=#3d352a
        palette = 1=#cd5c5c
        palette = 2=#86af80
        palette = 3=#e8ae5b
        palette = 4=#6495ed
        palette = 5=#deb887
        palette = 6=#b0c4de
        palette = 7=#bbaa99
        palette = 8=#554444
        palette = 9=#cc5533
        palette = 10=#88aa22
        palette = 11=#ffa75d
        palette = 12=#87ceeb
        palette = 13=#996600
        palette = 14=#b0c4de
        palette = 15=#ddccbb
        background = #1c1c1c
        foreground = #ddeedd
        cursor-color = #e2bbef
        cursor-text = #000000
        selection-background = #4d4d4d
        selection-foreground = #ffffff

        """

    /// The "GitHub Light" theme, in Ghostty theme-file syntax.
    static let lightTheme = """
        palette = 0=#24292f
        palette = 1=#cf222e
        palette = 2=#116329
        palette = 3=#4d2d00
        palette = 4=#0969da
        palette = 5=#8250df
        palette = 6=#1b7c83
        palette = 7=#6e7781
        palette = 8=#57606a
        palette = 9=#a40e26
        palette = 10=#1a7f37
        palette = 11=#633c01
        palette = 12=#218bff
        palette = 13=#a475f9
        palette = 14=#3192aa
        palette = 15=#8c959f
        background = #ffffff
        foreground = #1f2328
        cursor-color = #0969da
        cursor-text = #ffffff
        selection-background = #b6e3ff
        selection-foreground = #1f2328

        """

    /// The defaults file's contents. `themes` is nil when the theme files could
    /// not be written; the terminal then keeps libghostty's own colours.
    static func text(themes: GhosttyThemeFiles.Paths?) -> String {
        var text = """
            # Casper's built-in libghostty defaults: the terminal themes and the
            # clipboard-write policy.
            # Loaded before the user's own Ghostty config; any user setting overrides it.

            """
        if let themes {
            text += "theme = light:\(themes.light.path),dark:\(themes.dark.path)\n"
        }
        text += """
            # libghostty defaults this to `allow`, under which the write callback is
            # always trusted; `ask` keeps GhosttyClipboardWrite.approveUntrusted the
            # one place the write policy is decided.
            clipboard-write = ask
            """
        return text
    }
}
