import AppKit
import CasperCore
import Foundation

/// GUI entry point invoked from the single-binary fork in `main.swift`.
public enum CasperUI {
    @MainActor
    public static func runApp() -> Never {
        do {
            AppLaunch.sessionIdentity = try SessionIdentity.parse(arguments: CommandLine.arguments)
        } catch let error as SessionIdentity.ParseError {
            let message: String
            switch error {
            case .missingValue: message = "error: --session requires a name\n"
            case .invalidName(let name):
                message = "error: invalid --session name '\(name)' "
                    + "(use 1-32 chars from [A-Za-z0-9._-])\n"
            }
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
        NSApplication.shared.setActivationPolicy(.regular)
        CasperApp.main()
        fatalError("CasperApp.main() does not return")
    }
}
