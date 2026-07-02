#if DEBUG
import ArgumentParser
import CasperCore
import Foundation

/// `casper debug` — drive and observe the running GUI. Debug builds only.
struct DebugCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "Drive and observe the running Casper GUI (debug builds only).",
        subcommands: [
            DumpState.self, ReadText.self, SendText.self, SendKeys.self, SendCtrl.self,
            Screenshot.self, Focus.self,
        ])
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
        throw exitWithError(error.reason)
    }
    guard response.ok else {
        throw exitWithError(response.error ?? "unknown")
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
        @Option(name: .long, help: "Surface id to read (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Idempotent: re-reading text is safe, so allow a bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .readText, scrollback: scrollback, target: target),
                socket: socket.path, retriable: true)
            print(response.text ?? "")
        }
    }

    struct SendText: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Inject text into a surface.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to send.") var text: String
        @Flag(name: .long, help: "Submit the line by pressing Return.")
        var enter = false
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Mutating: retrying could inject the text more than once, so never
            // retry this verb.
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct SendKeys: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-keys",
            abstract: "Inject text as real per-character key events (press + release).")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to type as key events.") var text: String
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Mutating: retrying could type the text more than once, so never
            // retry this verb.
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendKeys, text: text, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct SendCtrl: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "send-ctrl",
            abstract: "Inject Ctrl+<letter> as a real key event (press + release).")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Letters to send as Ctrl combinations.") var text: String
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Mutating: retrying could inject the control combo more than once, so
            // never retry this verb.
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendCtrl, text: text, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String
        @Option(name: .long, help: "Surface id to capture (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            // Idempotent: re-capturing overwrites the same PNG, so allow a
            // bounded retry.
            let response = try CasperCLI.run(
                DebugCommand(verb: .screenshot, path: path, target: target),
                socket: socket.path, retriable: true)
            print(response.text ?? path)
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give UI focus to a surface by id.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Surface id to focus (see dump-state).") var id: String

        func run() throws {
            // Mutating (changes UI focus): never retry.
            _ = try CasperCLI.run(
                DebugCommand(verb: .focus, target: id), socket: socket.path, retriable: false)
        }
    }
}
#endif
