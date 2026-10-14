import AppKit

/// Casper's built-in libghostty defaults, baked into the binary and loaded *before* the
/// user's own Ghostty config (see `GhosttyConfigBuilder`), so any user setting still
/// overrides them: the terminal colours and the clipboard-write policy, whose reason sits
/// next to its line in `text(themes:)`.
///
/// The colours ship as two Ghostty themes, "Arthur" (dark) and "GitHub Light",
/// written to disk by `GhosttyThemeFiles` and selected by one conditional
/// `theme = light:<path>,dark:<path>` line, so the terminal follows the system
/// appearance. They are themes rather than explicit `background = …` keys
/// because in Ghostty an explicit colour key beats any theme, whichever file set
/// it: explicit defaults would mask a `theme` in the user's own config.
///
/// Each theme's `background` is not a literal: it is the app's content background,
/// `NSColor.textBackgroundColor`, resolved under the theme's appearance when the files are
/// written (`contentBackgroundHex(for:)`). That is the background of the content panes
/// beside the terminal (the diff view, the browser and `SurfaceHostView`'s fallback), so
/// the terminal reads as part of the same surface. The OS owns that colour and it differs
/// across macOS versions, so it cannot be hard-coded.
enum GhosttyDefaultConfig {
    /// The "Arthur" theme, in Ghostty theme-file syntax, on the given `#rrggbb` background.
    static func darkTheme(background: String) -> String {
        """
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
        background = \(background)
        foreground = #ddeedd
        cursor-color = #e2bbef
        cursor-text = #000000
        selection-background = #4d4d4d
        selection-foreground = #ffffff

        """
    }

    /// The "GitHub Light" theme, in Ghostty theme-file syntax, on the given `#rrggbb`
    /// background.
    static func lightTheme(background: String) -> String {
        """
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
        background = \(background)
        foreground = #1f2328
        cursor-color = #0969da
        cursor-text = #ffffff
        selection-background = #b6e3ff
        selection-foreground = #1f2328

        """
    }

    /// The app's content background (`NSColor.textBackgroundColor`) under the given
    /// appearance, as lowercase `#rrggbb`. It is what the panes beside the terminal paint
    /// on every macOS version (on macOS 26 it equals the window background), whereas
    /// `windowBackgroundColor` differs from it on macOS 15. Resolved at runtime because the
    /// OS owns the colour. Falls back to the colours Casper shipped before the terminal
    /// followed the appearance (white, `#1c1c1c`) if the colour has no sRGB form.
    static func contentBackgroundHex(for name: NSAppearance.Name) -> String {
        let fallback = name == .darkAqua ? "#1c1c1c" : "#ffffff"
        guard let appearance = NSAppearance(named: name) else { return fallback }
        var hex = fallback
        appearance.performAsCurrentDrawingAppearance {
            guard let color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) else { return }
            let bytes = [color.redComponent, color.greenComponent, color.blueComponent].map { component in
                min(max(Int((component * 255).rounded()), 0), 255)
            }
            hex = String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
        }
        return hex
    }

    /// The conditional `theme` line selecting Casper's light or dark theme file.
    static func themeLine(_ themes: GhosttyThemeFiles.Paths) -> String {
        "theme = light:\(themes.light.path),dark:\(themes.dark.path)"
    }

    /// Whether a libghostty config diagnostic reports a failed `theme` load. libghostty
    /// (`src/config/theme.zig`) words these as `theme "<name>" not found…`,
    /// `theme "<name>" cannot include path separators…`, `failed to load theme …` and
    /// `not reading theme from …`; matching on those shapes keeps unrelated diagnostics
    /// (unknown fields, compatibility handlers) from triggering the fallback.
    static func isThemeLoadFailure(_ message: String) -> Bool {
        let shapes = ["theme \"", "failed to load theme", "not reading theme from"]
        return shapes.contains { message.contains($0) }
    }

    /// The defaults file's contents. `themes` is nil when the theme files could
    /// not be written; the terminal then keeps libghostty's own colours.
    static func text(themes: GhosttyThemeFiles.Paths?) -> String {
        var text = """
            # Casper's built-in libghostty defaults: the terminal themes and the
            # clipboard-write policy.
            # Loaded before the user's own Ghostty config; any user setting overrides it.

            """
        if let themes {
            text += themeLine(themes) + "\n"
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
