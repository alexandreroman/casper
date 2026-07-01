import CasperCLI
import Foundation

// Single-binary fork: empty argv launches the GUI (Plan 5); any subcommand runs
// the CLI. The GUI is not yet available, so GUI mode prints a notice for now.
switch LaunchMode.detect(arguments: CommandLine.arguments) {
case .gui:
    FileHandle.standardError.write(
        Data("Casper GUI is not available yet (arrives in Plan 5).\n".utf8))
case .cli:
    CasperCommand.main()
}
