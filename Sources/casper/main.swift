import CasperCLI
import CasperGhostty
import Foundation

// Single-binary fork: empty argv launches the GUI; any subcommand runs the CLI.
// Plan 4 GUI mode opens a minimal one-terminal demo window (Plan 5 replaces it
// with the real Casper app).
switch LaunchMode.detect(arguments: CommandLine.arguments) {
case .gui:
    GhosttyDemo.run(directory: FileManager.default.currentDirectoryPath)
case .cli:
    CasperCommand.main()
}
