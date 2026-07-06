/// How the single binary was invoked. A genuine CLI invocation starts with a
/// subcommand token (a non-dash word) or an explicit help/version flag; empty
/// argv or AppKit/system-injected launch flags (which all start with `-`, e.g.
/// `-NSDocumentRevisionsDebugMode`, `-psn_0_12345`, `-AppleLanguages`) mean the
/// app was launched → GUI.
public enum LaunchMode: Equatable {
    case gui
    case cli

    public static func detect(arguments: [String]) -> LaunchMode {
        guard let first = arguments.dropFirst().first else { return .gui }
        if first.hasPrefix("-") {
            return ["-h", "--help", "--version"].contains(first) ? .cli : .gui
        }
        return .cli
    }
}
