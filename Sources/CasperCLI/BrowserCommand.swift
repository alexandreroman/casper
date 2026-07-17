import ArgumentParser
import CasperCore
import Foundation

/// Unwrap a JSON-serialized value for `--raw` shell piping: a top-level JSON
/// string prints as its bare contents (no surrounding quotes), while every other
/// JSON token (number, bool, null, object, array) prints verbatim. Mirrors the
/// app-side `content` unwrap so `eval --raw` and `content --raw` behave alike.
func unwrappedRawValue(_ json: String) -> String {
    guard let data = json.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let string = value as? String else {
        return json
    }
    return string
}

/// `casper browser open <url>` / `casper browser close` — open a URL in, or
/// collapse, the workspace's browser panel.
struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Open or close a workspace's browser panel, or automate the page.",
        subcommands: [
            Open.self, Load.self, Close.self,
            Screenshot.self, Eval.self, Content.self, Click.self, TypeText.self, Key.self,
            Console.self, Wait.self, Reload.self, ScrollUp.self, ScrollDown.self,
            ScrollTop.self, ScrollBottom.self,
        ])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a URL in the browser panel.")

        @Argument(help: "URL to open.")
        var url: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !url.isEmpty else { throw exitWithError("missing url") }
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .browserOpen, workspace: selector, url: url)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Load: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Load a URL into the browser in the background (without opening the inspector panel).")

        @Argument(help: "URL to load.")
        var url: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !url.isEmpty else { throw exitWithError("missing url") }
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .browserLoad, workspace: selector, url: url)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the browser panel is showing.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserClose, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    // A page snapshot or a heavy script can take longer than the default 5 s, so
    // every automation subcommand uses a roomier timeout.
    private static let automationTimeout: TimeInterval = 15

    struct Screenshot: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a PNG screenshot of the browser page.",
            discussion: "With --width/--height/--url the page renders off-screen at the given viewport "
                + "(default 1280x800), independent of the visible panel — so responsive breakpoints render "
                + "faithfully. Without them, the live browser panel is captured.")

        @Option(name: .long, help: "Output PNG path (defaults to a temp file).")
        var out: String?
        @Option(name: .long, help: "Off-screen render viewport width (default 1280); renders independent of the panel.")
        var width: Int?
        @Option(name: .long, help: "Off-screen render viewport height (default 800); renders independent of the panel.")
        var height: Int?
        @Option(name: .long, help: "Capture this absolute URL off-screen instead of the current page.")
        var url: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            if let width, width <= 0 { throw exitWithError("--width must be a positive number of pixels") }
            if let height, height <= 0 { throw exitWithError("--height must be a positive number of pixels") }
            if let url {
                guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                    throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
                }
            }
            let path = out ?? Self.temporaryScreenshotPath()
            return ControlCommand(
                verb: .browserScreenshot, workspace: try requireSelector(target), url: url, path: path,
                width: width, height: height)
        }

        func run() throws {
            let command = try makeCommand()
            let response = try sendControl(command, retriable: false, timeout: automationTimeout)
            emit(ScreenshotOut(screenshot: response.text ?? command.path ?? "", workspace: response.workspace ?? ""))
        }

        /// A unique temp PNG path used when `--out` is omitted.
        static func temporaryScreenshotPath() -> String {
            (NSTemporaryDirectory() as NSString).appendingPathComponent("casper-screenshot-\(UUID().uuidString).png")
        }
    }

    struct Eval: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Evaluate JavaScript in the browser page.")

        @Argument(help: "JavaScript source to evaluate.")
        var script: String
        @Flag(name: .long, help: "Print just the raw result value instead of a JSON object.")
        var raw = false
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !script.isEmpty else { throw exitWithError("missing script") }
            return ControlCommand(verb: .browserEval, workspace: try requireSelector(target), script: script)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            let value = response.text ?? "null"
            if raw {
                print(unwrappedRawValue(value))
            } else {
                print(Self.resultLine(value: value, workspace: response.workspace ?? ""))
            }
        }

        /// Build `{"result":<value>,"workspace":"<id>"}`. `<value>` is the
        /// already-serialized JSON the app returned, embedded as a parsed value so
        /// it lands as a real JSON token — `Codable` can't emit raw JSON. Keys are
        /// sorted for deterministic, diff-friendly output.
        static func resultLine(value: String, workspace: String) -> String {
            let parsed = (try? JSONSerialization.jsonObject(
                with: Data(value.utf8), options: [.fragmentsAllowed])) ?? NSNull()
            let object: [String: Any] = ["result": parsed, "workspace": workspace]
            guard let data = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let string = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }
    }

    struct Content: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the browser page's HTML content.")

        @Option(name: .long, help: "CSS selector; defaults to the whole document.")
        var selector: String?
        @Flag(name: .long, help: "Print just the raw HTML instead of a JSON object.")
        var raw = false
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            if let selector, selector.isEmpty { throw exitWithError("empty selector") }
            return ControlCommand(verb: .browserContent, workspace: try requireSelector(target), selector: selector)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            let html = response.text ?? ""
            if raw {
                print(html)
            } else {
                emit(ContentOut(content: html, workspace: response.workspace ?? ""))
            }
        }
    }

    struct Click: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Click the first element matching a CSS selector.")

        @Argument(help: "CSS selector of the element to click.")
        var selector: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !selector.isEmpty else { throw exitWithError("missing selector") }
            return ControlCommand(verb: .browserClick, workspace: try requireSelector(target), selector: selector)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct TypeText: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into the first element matching a CSS selector.")

        @Argument(help: "CSS selector of the target element.")
        var selector: String
        @Argument(help: "Text to type into the element.")
        var text: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !selector.isEmpty else { throw exitWithError("missing selector") }
            guard !text.isEmpty else { throw exitWithError("missing text") }
            return ControlCommand(
                verb: .browserType, workspace: try requireSelector(target), selector: selector, value: text)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Key: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dispatch a keydown/keyup KeyboardEvent to the page.")

        @Argument(help: "Key name to dispatch (e.g. Enter, Escape, a).")
        var key: String
        @Option(name: .long, help: "CSS selector of the target; defaults to the focused element.")
        var selector: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !key.isEmpty else { throw exitWithError("missing key") }
            if let selector, selector.isEmpty { throw exitWithError("empty selector") }
            return ControlCommand(
                verb: .browserKey, workspace: try requireSelector(target), selector: selector, key: key)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Console: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the page's captured console output and uncaught errors.")

        @Option(name: .long, help: "Only entries at or above this severity: debug, log, info, warn, error.")
        var level: String?
        @Flag(name: .long, help: "Drain the buffer after reading it.")
        var clear = false
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            if let level, ConsoleLevel(rawValue: level) == nil {
                throw exitWithError("invalid level '\(level)' (expected debug, log, info, warn, or error)")
            }
            return ControlCommand(
                verb: .browserConsole, workspace: try requireSelector(target),
                level: level, clear: clear ? true : nil)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            print(Self.consoleLine(entries: response.text ?? "[]", workspace: response.workspace ?? ""))
        }

        /// Build `{"console":[…],"workspace":"<id>"}` from the app's already-
        /// serialized JSON array (mirrors `Eval.resultLine`). The array is re-parsed
        /// so it embeds as a JSON token, not an escaped string. Keys are sorted for
        /// deterministic output.
        static func consoleLine(entries: String, workspace: String) -> String {
            let parsed = (try? JSONSerialization.jsonObject(
                with: Data(entries.utf8), options: [.fragmentsAllowed])) ?? []
            let object: [String: Any] = ["console": parsed, "workspace": workspace]
            guard let data = try? JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let string = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return string
        }
    }

    struct Wait: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Block until a selector or JS predicate condition holds.")

        @Argument(help: "CSS selector to wait for (omit when using --js).")
        var selector: String?
        @Option(name: .long, help: "JavaScript predicate to wait until truthy.")
        var js: String?
        @Flag(name: .long, help: "Wait until the selector is visible (selector form only).")
        var visible = false
        @Flag(name: .long, help: "Wait until the selector is gone (selector form only).")
        var gone = false
        @Option(name: .long, help: "Timeout in milliseconds (default 5000).")
        var timeout: Int?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            let hasSelector = !(selector?.isEmpty ?? true)
            let hasJS = !(js?.isEmpty ?? true)
            guard hasSelector != hasJS else {
                throw exitWithError("provide exactly one of a <selector> argument or --js <expr>")
            }
            if visible && gone {
                throw exitWithError("--visible and --gone are mutually exclusive")
            }
            if hasJS && (visible || gone) {
                throw exitWithError("--visible and --gone apply to the selector form only, not --js")
            }
            let ms = timeout ?? 5000
            guard ms > 0 else { throw exitWithError("--timeout must be a positive number of milliseconds") }
            return ControlCommand(
                verb: .browserWait, workspace: try requireSelector(target),
                selector: hasSelector ? selector : nil, predicate: hasJS ? js : nil,
                waitTimeout: ms, visible: visible ? true : nil, gone: gone ? true : nil)
        }

        func run() throws {
            let command = try makeCommand()
            // Give the socket read a margin beyond the app-side deadline so the reply
            // always arrives before the client gives up.
            let socketTimeout = TimeInterval((command.waitTimeout ?? 5000) / 1000 + 5)
            let response = try sendControl(command, retriable: false, timeout: socketTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Reload: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reload the browser page, optionally waiting for it to finish loading.")

        @Flag(name: .long, help: "Also wait until the page finishes loading (readyState complete).")
        var wait = false
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .browserReload, workspace: try requireSelector(target),
                waitReady: wait ? true : nil)
        }

        func run() throws {
            // Deliberate simplification: unlike `wait` (whose socket timeout is
            // derived from a user-supplied `--timeout`), reload's app-side wait
            // deadline is a fixed 5 s, comfortably within the 15 s automation socket
            // timeout — so no dynamic derivation is needed, regardless of `--wait`.
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct ScrollUp: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll-up",
            abstract: "Scroll the browser page up by one viewport.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserScrollUp, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct ScrollDown: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll-down",
            abstract: "Scroll the browser page down by one viewport.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserScrollDown, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct ScrollTop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll-top",
            abstract: "Scroll the browser page to the top.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserScrollTop, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct ScrollBottom: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scroll-bottom",
            abstract: "Scroll the browser page to the bottom.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserScrollBottom, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false, timeout: automationTimeout)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
