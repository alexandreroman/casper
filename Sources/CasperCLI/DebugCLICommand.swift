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

private func run(_ command: DebugCommand, socket: String, retriable: Bool = false) throws -> DebugResponse {
    let response: DebugResponse
    do {
        response = try DebugSocketClient.send(command, toSocketAt: socket, retriable: retriable)
    } catch let error as DebugSocketError {
        FileHandle.standardError.write(Data("error: \(error.reason)\n".utf8))
        throw ExitCode.failure
    }
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
            // Idempotent: re-reading state is safe, so recover from transient
            // transport failures with a bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .dumpState), socket: socket.path, retriable: true)
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
            // Idempotent: re-reading text is safe, so allow a bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .readText, scrollback: scrollback),
                socket: socket.path, retriable: true)
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
            // Mutating: retrying could inject the text more than once, so never
            // retry this verb.
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter),
                socket: socket.path, retriable: false)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String

        func run() throws {
            // Idempotent: re-capturing overwrites the same PNG, so allow a
            // bounded retry — this is the verb whose slow handler triggers the
            // transient transport failure in the first place.
            let response = try CasperCLI.run(
                DebugCommand(verb: .screenshot, path: path), socket: socket.path, retriable: true)
            print(response.text ?? path)
        }
    }
}
#endif
