#if DEBUG
import ArgumentParser
import CasperCore
import Foundation

/// `casper debug` — drive and observe the running GUI. Debug builds only.
struct DebugCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Drive and observe the running Casper GUI (debug builds only).",
        subcommands: [DumpState.self, ReadText.self, SendText.self, Screenshot.self])
}

/// Shared socket-path option.
struct SocketOption: ParsableArguments {
    @Option(name: .long, help: "Debug socket path (defaults to CASPER_DEBUG_SOCKET or /tmp/casper-debug.sock).")
    var socket: String?

    var path: String { socket ?? DebugSocketPath.default }
}

private func run(_ command: DebugCommand, socket: String) throws -> DebugResponse {
    let response = try DebugSocketClient.send(command, toSocketAt: socket)
    guard response.ok else {
        FileHandle.standardError.write(Data("error: \(response.error ?? "unknown")\n".utf8))
        throw ExitCode.failure
    }
    return response
}

extension DebugCLICommand {
    struct DumpState: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print app state as JSON.")
        @OptionGroup var socket: SocketOption

        func run() throws {
            let response = try CasperCLI.run(DebugCommand(verb: .dumpState), socket: socket.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response.state ?? DebugState(surfaces: []))
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct ReadText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the terminal's text.")
        @OptionGroup var socket: SocketOption
        @Flag(name: .long, help: "Include scrollback (full screen), not just the viewport.")
        var scrollback = false

        func run() throws {
            let response = try CasperCLI.run(
                DebugCommand(verb: .readText, scrollback: scrollback), socket: socket.path)
            print(response.text ?? "")
        }
    }

    struct SendText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inject text into the focused surface.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to send.") var text: String
        @Flag(name: .long, help: "Append a trailing newline (press Return).")
        var enter = false

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter), socket: socket.path)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String

        func run() throws {
            let response = try CasperCLI.run(
                DebugCommand(verb: .screenshot, path: path), socket: socket.path)
            print(response.text ?? path)
        }
    }
}
#endif
