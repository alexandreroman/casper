import CasperCLI
import CasperUI

// Single-binary fork: empty argv launches the GUI; any subcommand runs the CLI.
switch LaunchMode.detect(arguments: CommandLine.arguments) {
case .gui:
    CasperUI.runApp()
case .cli:
    CasperCommand.main()
}
