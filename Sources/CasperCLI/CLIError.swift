import ArgumentParser
import Foundation

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
