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
/// (`progress clear`, `notify`, `browser open`, `diff show`).
struct WorkspaceRefOut: Encodable {
    let workspace: String
}

/// `{"command":"...","cwd":"...","workspace":"<id>"}` — the created terminal for
/// `terminal new`. `command`/`cwd` are echoed only when they were specified;
/// `JSONEncoder` omits nil optionals, so an unspecified field simply won't appear.
struct TerminalNewOut: Encodable {
    let workspace: String
    let command: String?
    let cwd: String?
}

/// `{"id":"...","name":"...","branch":"...","path":"..."}` — one workspace
/// descriptor, used as an array element for `workspace list`.
struct WorkspaceOut: Encodable {
    let id: String
    let name: String
    let branch: String
    let path: String
}

/// `{"path":"...","workspace":"<id>"}` — the current workspace for
/// `workspace current`. `path` is omitted when the id isn't found in the app's
/// workspace list, so the caller still gets the id.
struct CurrentOut: Encodable {
    let workspace: String
    let path: String?
}

/// `{"workspace":"<new id>","name":"...","branch":"...","path":"..."}` — the
/// created workspace for `workspace new`. The new id is keyed as `workspace`
/// (matching the affected-workspace convention), not `id`.
struct WorkspaceNewOut: Encodable {
    let workspace: String
    let name: String
    let branch: String
    let path: String
}

/// `{"error":"<message>"}` — the sole error shape, written to stderr.
struct ErrorOut: Encodable {
    let error: String
}
