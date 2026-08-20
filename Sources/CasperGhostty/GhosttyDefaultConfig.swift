/// Casper's built-in libghostty defaults, baked into the binary and loaded
/// *before* the user's own Ghostty config so any user setting still overrides
/// them: the "Arthur" terminal theme and the clipboard-write policy.
///
/// The theme is embedded because, on macOS, libghostty resolves the user's config
/// directory from the running app's bundle identifier
/// (`~/Library/Application Support/<CFBundleIdentifier>/`). A bundled `Casper.app`
/// is keyed on `com.github.alexandreroman.casper`, whose config dir is empty, so without
/// this embedded default the bundle would render libghostty's vanilla `#282c34`
/// gray instead of the theme the dev build shows.
///
/// The colors are inlined (no `themes/` dir or `GHOSTTY_RESOURCES_DIR` needed),
/// keeping the default self-contained.
///
/// `clipboard-write` is set to `ask` because libghostty's own default is `allow`,
/// which lets anything a terminal prints — a `cat`ed file, an agent's output, a
/// build log — silently replace the user's clipboard with an OSC 52 escape. `ask`
/// makes libghostty raise the `confirm` flag on its write-clipboard callback, so
/// the write goes through `GhosttyClipboardWrite`'s confirmation prompt. A user who
/// prefers the upstream behaviour can override it with `clipboard-write = allow`.
enum GhosttyDefaultConfig {
    static let text = """
        # Casper's built-in libghostty defaults: the Arthur theme and the
        # clipboard-write policy.
        # Loaded before the user's own Ghostty config; any user setting overrides it.
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
        # libghostty defaults this to `allow`, which lets any terminal output
        # replace the clipboard via OSC 52; `ask` routes the write through
        # Casper's confirmation prompt.
        clipboard-write = ask
        """
}
