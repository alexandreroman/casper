import ArgumentParser
import Foundation

/// Write a clean `error: <message>` to stderr and signal a failing exit.
///
/// Shared by every CLI subcommand so user-facing failures read the same way and
/// raw Foundation errors (`Error Domain=… Code=…`) never leak through
/// ArgumentParser's default handler.
func exitWithError(_ message: String) -> ExitCode {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return .failure
}
