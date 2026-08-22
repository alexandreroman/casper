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
            DumpState.self, ReadText.self, SendText.self, SendKeys.self, SendKey.self,
            SendAction.self, MouseMove.self, Screenshot.self, Focus.self,
        ])
}

/// Shared socket-path option.
struct SocketOption: ParsableArguments {
    @Option(
        name: .long,
        help: ArgumentHelp(
            "Debug socket path (defaults to CASPER_DEBUG_SOCKET, else the CASPER_SESSION-derived "
                + "socket, else /tmp/casper-debug.sock)."))
    var socket: String?

    var path: String { socket ?? DebugSocketPath.default }
}

/// Send one debug command and unwrap the reply, turning a transport failure or an
/// `ok: false` answer into a thrown `ExitCode`.
///
/// `retriable` says whether a transport-level resend is safe. It is `true` only
/// for the observing verbs — re-reading state or text, or re-capturing a
/// screenshot over the same file, leaves the app exactly as it was. Every verb
/// that drives the GUI passes `false`: a resend would inject the text, key or
/// action a second time.
private func run(_ command: DebugCommand, socket: String, retriable: Bool) throws -> DebugResponse {
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
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendText, text: text, enter: enter, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct SendKeys: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inject text as real per-character key events (press + release).")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Text to type as key events.") var text: String
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendKeys, text: text, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct SendKey: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inject a key with modifiers as a real key event (press + release).")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Character to send, e.g. c") var text: String
        @Option(name: .long, parsing: .upToNextOption,
                help: "Modifiers: ctrl, cmd, opt, shift (repeatable).") var mods: [String] = []
        @Option(name: .long, help: "Surface id (defaults to focused).") var target: String?

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendKey, text: text, mods: mods, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct SendAction: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Trigger a libghostty keybinding action by name (e.g. copy_to_clipboard).")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Action name, e.g. copy_to_clipboard") var text: String
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .sendAction, text: text, target: target),
                socket: socket.path, retriable: false)
        }
    }

    struct MouseMove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inject a mouse position (libghostty top-left coordinates) into a surface.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "X position, in libghostty top-left coordinates.") var x: Double
        @Argument(help: "Y position, in libghostty top-left coordinates.") var y: Double
        @Option(name: .long, help: "Surface id to send to (see dump-state; defaults to the focused surface).")
        var target: String?

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .mouseMove, target: target, x: x, y: y),
                socket: socket.path, retriable: false)
        }
    }

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a PNG of the app window.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Output PNG path.") var path: String
        @Option(name: .long, help: "Surface id to capture (see dump-state; defaults to the focused surface).")
        var target: String?

        func makeCommand() -> DebugCommand {
            DebugCommand(verb: .screenshot, path: absolutePath(path), target: target)
        }

        func run() throws {
            let command = makeCommand()
            let response = try CasperCLI.run(command, socket: socket.path, retriable: true)
            print(response.text ?? command.path ?? "")
        }
    }

    struct Focus: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Give UI focus to a surface by id.")
        @OptionGroup var socket: SocketOption
        @Argument(help: "Surface id to focus (see dump-state).") var id: String

        func run() throws {
            _ = try CasperCLI.run(
                DebugCommand(verb: .focus, target: id), socket: socket.path, retriable: false)
        }
    }
}
#endif
