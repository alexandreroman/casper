import ArgumentParser
import Foundation

/// Shared encoder for all CLI JSON output. `sortedKeys` gives deterministic,
/// diff-friendly output; `withoutEscapingSlashes` keeps URLs like `https://x`
/// readable instead of `https:\/\/x`.
let cliJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

/// Encode `value` as a single JSON line (no trailing newline; callers `print` it).
/// Falls back to `"{}"` if encoding throws — it never does for the CLI's own
/// `Encodable` value types.
func jsonLine<T: Encodable>(_ value: T) -> String {
    guard let data = try? cliJSONEncoder.encode(value),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

/// Print `value` as one JSON line to stdout (with a trailing newline).
func emit<T: Encodable>(_ value: T) {
    print(jsonLine(value))
}

/// Print one read-only result: with `--raw` the bare value, ready to pipe into
/// another shell command, otherwise the command's JSON object. `browser eval`,
/// `browser content`, and `browser url` differ only in what those two renderings
/// are, so only the unused one is left unevaluated.
func emitResult(raw: Bool, plain: @autoclosure () -> String, json: @autoclosure () -> String) {
    print(raw ? plain() : json())
}

/// Unwrap a JSON-serialized value for `--raw` shell piping: a top-level JSON
/// string prints as its bare contents (no surrounding quotes), while every other
/// JSON token (number, bool, null, object, array) prints verbatim. Mirrors the
/// app-side `content` unwrap so `eval --raw` and `content --raw` behave alike.
func unwrappedRawValue(_ json: String) -> String {
    guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]),
          let string = value as? String else {
        return json
    }
    return string
}

/// Build `{"<key>":<json>,"workspace":"<id>"}` from a payload the app already
/// serialized. `json` is re-parsed so it embeds as a real JSON token instead of an
/// escaped string — `Codable` can't emit raw JSON — falling back to `fallback`
/// when it does not parse. Keys are sorted for deterministic, diff-friendly
/// output.
func jsonLine(key: String, json: String, fallback: Any, workspace: String) -> String {
    let parsed = (try? JSONSerialization.jsonObject(
        with: Data(json.utf8), options: [.fragmentsAllowed])) ?? fallback
    let object: [String: Any] = [key: parsed, "workspace": workspace]
    guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

// MARK: - Success output shapes

/// `{"status":"<state>","workspace":"<id>"}`
struct StatusOut: Encodable {
    let status: String
    let workspace: String
}

/// `{"total":T,"current":C,"label":"L"}` — the body of a progress report.
struct ProgressBody: Encodable {
    let total: Int
    let current: Int
    let label: String
}

/// `{"progress":{…},"workspace":"<id>"}` — a progress report for `progress set`.
struct ProgressOut: Encodable {
    let progress: ProgressBody
    let workspace: String
}

/// `{"workspace":"<id>"}` — the sole "affected workspace" shape, shared by every
/// command whose only meaningful output is which workspace it acted on
/// (`progress clear`, `notify`, `browser open`, `diff open`).
struct WorkspaceRefOut: Encodable {
    let workspace: String
}

/// `{"terminal":"<id>","command":"...","working-dir":"...","workspace":"<id>"}` —
/// the created terminal for `terminal new`. `working-dir` is always present (the
/// resolved directory, defaulting to the workspace's worktree); `command` is
/// echoed only when specified, since `JSONEncoder` omits nil optionals.
struct TerminalNewOut: Encodable {
    let terminal: String
    let workspace: String
    let command: String?
    let workingDir: String

    enum CodingKeys: String, CodingKey {
        case terminal, workspace, command
        case workingDir = "working-dir"
    }
}

/// `{"terminal":"...","working-dir":"..."}` — one terminal descriptor, used as
/// an array element for `terminal list`. The id is keyed by its type name
/// (`terminal`), matching the entity-keyed-by-type-name convention. It carries no
/// `command`: a launch command is a one-shot instruction the terminal consumes at
/// startup, not durable state a listing could report back.
struct TerminalInfoOut: Encodable {
    let terminal: String
    let workingDir: String

    enum CodingKeys: String, CodingKey {
        case terminal
        case workingDir = "working-dir"
    }
}

/// `{"terminal":"<id>","workspace":"<id>"}` — the closed terminal for
/// `terminal close`.
struct TerminalCloseOut: Encodable {
    let terminal: String
    let workspace: String
}

/// `{"workspace":"...","name":"...","branch":"...","path":"..."}` — one workspace
/// descriptor, used as an array element for `workspace list`. The id is keyed by
/// its type name (`workspace`), matching the entity-keyed-by-type-name
/// convention. `branch` is omitted when unknown (a degenerate space stores it as
/// an empty string).
struct WorkspaceOut: Encodable {
    let workspace: String
    let name: String
    let branch: String?
    let path: String
}

/// `{"workspace":"<id>","name":"...","branch":"...","path":"..."}` — the current
/// workspace for `workspace current`. Mirrors a `workspace list` descriptor: when
/// the id resolves in the app's workspace list, `name`/`branch`/`path` are
/// populated; each is omitted when unknown, so an unresolved id still yields the
/// bare `{"workspace"}`.
struct CurrentOut: Encodable {
    let workspace: String
    let name: String?
    let branch: String?
    let path: String?
}

/// `{"workspace":"<new id>","name":"...","branch":"...","path":"...","command":"..."}` —
/// the created workspace for `workspace new`. The new id is keyed as `workspace`
/// (matching the affected-workspace convention), not `id`. `branch` is omitted
/// when unknown, matching `WorkspaceOut`; `command` is echoed only when specified,
/// matching `TerminalNewOut`.
struct WorkspaceNewOut: Encodable {
    let workspace: String
    let name: String
    let branch: String?
    let path: String
    let command: String?
}

/// `{"command":"<name>","terminal":"<id>","workspace":"<id>"}` — the launched
/// named command for `casper run`.
struct RunOut: Encodable {
    let command: String
    let terminal: String
    let workspace: String
}

/// `{"screenshot":"<path>","workspace":"<id>"}` — the saved PNG path for
/// `browser screenshot`.
struct ScreenshotOut: Encodable {
    let screenshot: String
    let workspace: String
}

/// `{"content":"<html>","workspace":"<id>"}` — the page HTML for `browser
/// content` (non-`--raw`).
struct ContentOut: Encodable {
    let content: String
    let workspace: String
}

/// `{"url":"<href>","workspace":"<id>"}` — the current page URL for `browser
/// url` (non-`--raw`).
struct URLOut: Encodable {
    let url: String
    let workspace: String
}

// MARK: - Error output

/// `{"error":"<message>"}` — the sole error shape, written to stderr.
struct ErrorOut: Encodable {
    let error: String
}

/// Write a `{"error":"<message>"}` JSON line to stderr and signal a failing exit.
///
/// Shared by every CLI subcommand so user-facing failures read the same way and
/// raw Foundation errors (`Error Domain=… Code=…`) never leak through
/// ArgumentParser's default handler. Encoding via `ErrorOut` keeps the message
/// correctly JSON-escaped.
func exitWithError(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data((jsonLine(ErrorOut(error: message)) + "\n").utf8))
    return .failure
}
