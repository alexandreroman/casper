import ArgumentParser
import CasperCore
import Foundation

/// `casper info set …` / `casper info clear` — publish or drop a workspace's
/// info-panel message. The panel keeps only the latest message and never
/// persists it, so `set` replaces whatever is there and `clear` empties it.
struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Publish a Markdown message in a workspace's info panel.",
        subcommands: [Set.self, Clear.self])

    struct Set: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(
            abstract: "Replace the info panel's Markdown message.")

        @Option(name: .long, help: "Markdown message; omit to read --file or stdin.")
        var message: String?
        @Option(name: .long, help: "Read the Markdown message from a file.")
        var file: String?
        @Argument(help: "Pass '-' to read the Markdown message from stdin.")
        var source: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .infoSet, workspace: try requireSelector(target),
                message: try resolveMarkdown())
        }

        /// Resolve the message body from exactly one source: `--message`, then
        /// `--file`, then stdin. `readStdin` and `isStandardInputATTY` are injected
        /// so tests exercise the stdin path — and the TTY guard below — without a
        /// real pipe or terminal.
        func resolveMarkdown(
            readStdin: () throws -> String = Set.readStandardInput,
            isStandardInputATTY: () -> Bool = Set.isStandardInputATTY
        ) throws -> String {
            if let source, source != "-" {
                throw exitWithError("unexpected argument '\(source)' (pass '-' to read stdin)")
            }
            // A '-' counts as a source of its own, so `--message x -` is a conflict
            // rather than a silently ignored stdin request.
            let sourceCount = [message != nil, file != nil, source != nil].filter { $0 }.count
            guard sourceCount <= 1 else {
                throw exitWithError("pass exactly one of --message, --file, or '-' (stdin)")
            }
            let raw: String
            if let message {
                raw = message
            } else if let file {
                raw = try Self.readMarkdownFile(file)
            } else {
                // An explicit '-' means the caller means it: read stdin unconditionally.
                // With no source at all, only fall back to stdin when it is not an
                // interactive terminal — otherwise a bare `casper info set` would hang
                // silently waiting for Ctrl-D instead of failing fast.
                if source == nil, isStandardInputATTY() {
                    throw exitWithError(
                        "no message given: pass --message <text>, --file <path>, or pipe/redirect "
                            + "content to stdin")
                }
                raw = try readStdin()
            }
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw exitWithError("empty message (use 'casper info clear' to empty the panel)")
            }
            guard raw.utf8.count <= ControlCommand.infoMessageMaxBytes else {
                throw exitWithError(
                    "message too large (\(raw.utf8.count) bytes, max \(ControlCommand.infoMessageMaxBytes))")
            }
            return raw
        }

        /// Read `--file` as UTF-8, rejecting an oversized file on its stat rather
        /// than after loading it whole. The underlying error is reported verbatim so
        /// a permissions problem, a missing file, and non-UTF-8 content stay
        /// distinguishable.
        static func readMarkdownFile(_ path: String) throws -> String {
            let byteCount: Int
            do {
                byteCount = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            } catch {
                throw exitWithError("cannot read file '\(path)': \(error.localizedDescription)")
            }
            guard byteCount <= ControlCommand.infoMessageMaxBytes else {
                throw exitWithError(
                    "file '\(path)' too large (\(byteCount) bytes, max \(ControlCommand.infoMessageMaxBytes))")
            }
            do {
                return try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                throw exitWithError("cannot read file '\(path)': \(error.localizedDescription)")
            }
        }

        /// Drain stdin as UTF-8. Split out so `resolveMarkdown` stays testable.
        static func readStandardInput() throws -> String {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else {
                throw exitWithError("stdin is not valid UTF-8")
            }
            return text
        }

        /// Whether stdin is an interactive terminal rather than a pipe or
        /// redirect. Split out so `resolveMarkdown` stays testable.
        static func isStandardInputATTY() -> Bool {
            isatty(STDIN_FILENO) != 0
        }
    }

    struct Clear: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(
            abstract: "Empty the info panel and hide its button.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .infoClear, workspace: try requireSelector(target))
        }
    }
}
