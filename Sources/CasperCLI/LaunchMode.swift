/// How the single binary was invoked. A genuine CLI invocation starts with a
/// subcommand token (a non-dash word) or an explicit help/version flag; empty
/// argv or AppKit/system-injected launch flags (which all start with `-`, e.g.
/// `-NSDocumentRevisionsDebugMode`, `-psn_0_12345`, `-AppleLanguages`) mean the
/// app was launched → GUI.
public enum LaunchMode: Equatable {
    case gui
    case cli

    private static let helpFlags: Set<String> = ["-h", "--help", "--version"]

    public static func detect(arguments: [String]) -> LaunchMode {
        guard let first = arguments.dropFirst().first else { return .gui }
        if first.hasPrefix("-") {
            return helpFlags.contains(first) ? .cli : .gui
        }
        return .cli
    }
}
