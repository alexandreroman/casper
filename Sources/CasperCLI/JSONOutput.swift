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

/// `{"progress":<body|null>,"workspace":"<id>"}`. The `progress` key is always
/// present: a cleared progress must serialize as an explicit `{"progress":null}`,
/// which the default synthesized encoding would omit.
struct ProgressOut: Encodable {
    let progress: ProgressBody?
    let workspace: String

    private enum CodingKeys: String, CodingKey {
        case progress
        case workspace
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let progress {
            try container.encode(progress, forKey: .progress)
        } else {
            try container.encodeNil(forKey: .progress)
        }
        try container.encode(workspace, forKey: .workspace)
    }
}

/// `{"pendingNotification":<bool>,"workspace":"<id>"}`
struct NotifyOut: Encodable {
    let pendingNotification: Bool
    let workspace: String
}

/// `{"terminal":{"opened":true},"workspace":"<id>"}`
struct TerminalOut: Encodable {
    let terminal: Opened
    let workspace: String
}

struct Opened: Encodable {
    let opened: Bool
}

/// `{"browser":{"url":"<url>"},"workspace":"<id>"}`
struct BrowserOut: Encodable {
    let browser: BrowserBody
    let workspace: String
}

struct BrowserBody: Encodable {
    let url: String
}

/// `{"view":"diff","workspace":"<id>"}`
struct DiffOut: Encodable {
    let view: String
    let workspace: String
}

/// `{"id":"...","name":"...","branch":"..."}` — one workspace descriptor, used
/// as an array element for `workspace list`.
struct WorkspaceOut: Encodable {
    let id: String
    let name: String
    let branch: String
}

/// `{"workspace":"<new id>","name":"...","branch":"..."}` — the created
/// workspace for `workspace new`. The new id is keyed as `workspace` (matching
/// the affected-workspace convention), not `id`.
struct WorkspaceNewOut: Encodable {
    let workspace: String
    let name: String
    let branch: String
}

/// `{"workspace":"<CASPER_WORKSPACE_ID>"}`
struct CurrentOut: Encodable {
    let workspace: String
}

/// `{"error":"<message>"}` — the sole error shape, written to stderr.
struct ErrorOut: Encodable {
    let error: String
}
