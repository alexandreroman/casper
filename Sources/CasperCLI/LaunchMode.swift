import Foundation

/// How the single binary was invoked. Empty argv (only the program path) means
/// the user double-clicked / launched the app → GUI; any argument means CLI.
public enum LaunchMode: Equatable {
    case gui
    case cli

    public static func detect(arguments: [String]) -> LaunchMode {
        arguments.count <= 1 ? .gui : .cli
    }
}
