import Clibgit2
import Foundation

/// Process-wide libgit2 initialization. `git_libgit2_init` is reference-counted
/// by libgit2; we call it exactly once and never shut down (acceptable for a
/// long-lived app and for the test process).
public enum Libgit2 {
    private static let initialized: Bool = {
        git_libgit2_init() >= 0
    }()

    /// Ensure libgit2 is initialized. Safe to call repeatedly.
    public static func ensureInit() {
        // Accepted exception to the never-crash policy: libgit2 init failure is unrecoverable here.
        precondition(initialized, "git_libgit2_init failed")
    }
}

/// A libgit2 error: the raw negative return code plus the thread-local message.
public struct GitError: Error, Equatable, Sendable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

/// Throw a `GitError` when a libgit2 call returns a negative code; otherwise
/// return the (non-negative) code unchanged.
@discardableResult
func gitCheck(_ code: Int32) throws -> Int32 {
    guard code < 0 else { return code }
    let message: String
    if let last = git_error_last(), let cString = last.pointee.message {
        message = String(cString: cString)
    } else {
        message = "libgit2 error \(code)"
    }
    throw GitError(code: code, message: message)
}

/// Run `body` against a zeroed `git_strarray`, copy the entries into a Swift
/// array, and dispose the native array. `body` typically fills it via a libgit2
/// `*_list` call.
func gitStringArray(_ body: (inout git_strarray) throws -> Void) rethrows -> [String] {
    var array = git_strarray()
    defer { git_strarray_dispose(&array) }  // before body(): dispose on the throw path too
    try body(&array)
    var result: [String] = []
    result.reserveCapacity(array.count)
    for index in 0..<array.count {
        if let cString = array.strings[index] {
            result.append(String(cString: cString))
        }
    }
    return result
}
