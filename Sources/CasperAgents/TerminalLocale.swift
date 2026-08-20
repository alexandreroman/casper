import Foundation

/// Resolves a UTF-8 `LANG` value to inject into every terminal surface.
///
/// A macOS GUI app launched from Finder, the Dock, or Xcode inherits no
/// `LANG`/`LC_*`, so a shell (and programs it spawns, e.g. Claude) run under the
/// `C`/`POSIX` locale and decode correct UTF-8 bytes as Latin-1 — turning
/// `dépôt` into `dÃ©pÃ´t`. Terminal.app and standalone Ghostty avoid this by
/// exporting a UTF-8 `LANG`; Casper does the same. This enum stays pure and
/// testable: locale resolution is deterministic and the installed-locale probe
/// is injectable.
public enum TerminalLocale {
    /// The environment merged into every terminal surface: a single UTF-8 `LANG`.
    public static func environment(locale: Locale = .current) -> [String: String] {
        ["LANG": resolvedLANG(locale: locale)]
    }

    /// A UTF-8 POSIX `LANG` value derived from `locale` (e.g. `fr_FR.UTF-8`),
    /// used only when it can be formed and the C library recognizes it;
    /// otherwise `en_US.UTF-8`, which is always available on macOS.
    public static func resolvedLANG(
        locale: Locale = .current,
        isInstalled: (String) -> Bool = TerminalLocale.isInstalled
    ) -> String {
        guard let identifier = posixUTF8Identifier(from: locale), isInstalled(identifier) else {
            return "en_US.UTF-8"
        }
        return identifier
    }

    /// Builds `<lang>_<REGION>.UTF-8` from the locale using the modern language
    /// and region APIs; returns `nil` if either component is missing.
    private static func posixUTF8Identifier(from locale: Locale) -> String? {
        guard let language = locale.language.languageCode?.identifier,
              let region = locale.region?.identifier
        else {
            return nil
        }
        return "\(language)_\(region).UTF-8"
    }

    /// Reports whether the C library recognizes `name` as a locale, without
    /// mutating the process's global locale state.
    public static func isInstalled(_ name: String) -> Bool {
        guard let loc = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        freelocale(loc)
        return true
    }
}
