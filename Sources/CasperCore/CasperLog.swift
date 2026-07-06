import os

/// Central `os.Logger` facade. The subsystem is the stable key the `debug-casper`
/// skill filters on (`log show --predicate 'subsystem == "..."'`).
///
/// Gating discipline: `.error`/`.fault` calls stay compiled into release builds
/// for field crash diagnosis; verbose `.debug`/`.info` call sites are wrapped in
/// `#if DEBUG` at the call site.
public enum CasperLog {
    public static let subsystem = "com.github.alexandreroman.casper"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ghostty = Logger(subsystem: subsystem, category: "ghostty")
    public static let debug = Logger(subsystem: subsystem, category: "debug")
}

public extension Logger {
    /// Logs an operation failure, rendering the error public for field diagnosis.
    func failure(_ message: String, _ error: Error) {
        self.error("\(message, privacy: .public): \(String(describing: error), privacy: .public)")
    }
}
