import Clibgit2
import Foundation

/// Process-wide libgit2 initialization. `git_libgit2_init` is reference-counted
/// by libgit2; we call it exactly once and never shut down (acceptable for a
/// long-lived app and for the test process).
enum Libgit2 {
    private static let initialized: Bool = {
        // On success `git_libgit2_init` returns the (positive) number of
        // initializations of this library; only a negative value is a failure.
        guard git_libgit2_init() >= 0 else { return false }
        // Before any repository is opened, so every read of a config value — and every
        // `git_repository_init`, which reads `init.defaultBranch` — can already reach
        // Apple's system `gitconfig`.
        addAppleGitSystemConfigDirectories()
        return true
    }()

    /// Ensure libgit2 is initialized. Safe to call repeatedly.
    static func ensureInit() {
        // Accepted exception to the never-crash policy: libgit2 init failure is unrecoverable here.
        precondition(initialized, "git_libgit2_init failed")
    }

    /// The directories Apple's `git` reads its **system** configuration from, keeping
    /// only those that exist on disk.
    ///
    /// Apple compiles `git` to look for its system config in the active developer
    /// directory (`<developer dir>/usr/share/git-core/gitconfig`), which is where a
    /// macOS user's `init.defaultBranch`, `user.name` and friends commonly live.
    /// libgit2 searches `/etc` and the package manager's prefix instead, so without
    /// this it has no way of reaching the file the very `git` the user runs reads.
    ///
    /// **Known limitation:** an Xcode installed at a non-standard path with no
    /// `DEVELOPER_DIR` set in the environment is not found. Resolution stays inside
    /// Casper rather than being delegated to `xcode-select` — see the
    /// `shell-path-resolution` note — so that case is a graceful fallback: libgit2
    /// keeps its own search path and behaves as it would with no augmentation at all.
    static var appleGitSystemConfigDirectories: [String] {
        var candidates: [String] = []
        // What `xcode-select` exports, and the only announcement a non-standard Xcode
        // location makes.
        if let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !developerDir.isEmpty {
            candidates.append(developerDir + "/usr/share/git-core")
        }
        candidates.append("/Applications/Xcode.app/Contents/Developer/usr/share/git-core")
        candidates.append("/Library/Developer/CommandLineTools/usr/share/git-core")
        return candidates.filter(isDirectory)
    }

    /// Append `appleGitSystemConfigDirectories` to libgit2's system-level config
    /// search path, giving Apple's `gitconfig` a chance to be found where libgit2
    /// would otherwise find nothing at all.
    ///
    /// **A fallback, not a merge.** libgit2 resolves a config *level* to the **first
    /// existing file** along that level's search path, so appending puts Apple's
    /// directory *behind* everything libgit2 already searches. It is read only when no
    /// earlier directory on the path holds a `gitconfig`. On the common macOS setup —
    /// the default search path is `/etc`, and macOS ships no `/etc/gitconfig` — that
    /// makes Apple's file the system config, which is what moves a bare
    /// `git_repository_init` from `refs/heads/master` onto whatever
    /// `init.defaultBranch` says. Where `/etc/gitconfig` or a package manager's
    /// prefixed `gitconfig` does exist, that file is read **instead of** Apple's and
    /// this call changes nothing.
    ///
    /// The append order is the deliberate half of that trade: prepending would let
    /// Apple's file shadow a system config an administrator installed on purpose,
    /// which is a worse failure than being inert.
    ///
    /// The same option also governs libgit2's **shared attributes and ignore files**,
    /// so the appended directory can supply an `gitattributes` too — Apple's
    /// `git-core` ships one (`*.m diff=objc`, `*.swift diff=swift`). It selects diff
    /// drivers, which Casper's own diff rendering does not consult.
    ///
    /// The path is augmented, never replaced: a directory already listed is not added
    /// twice, so calling this repeatedly is a no-op after the first time.
    ///
    /// Every step is best-effort. A search path that cannot be read, or a
    /// `git_libgit2_opts` that refuses the new one, leaves libgit2 exactly as it was;
    /// initialization must not gain a failure mode over a configuration nicety.
    static func addAppleGitSystemConfigDirectories() {
        guard let current = systemConfigSearchPath() else { return }
        let augmented = searchPath(current, adding: appleGitSystemConfigDirectories)
        guard augmented != current else { return }
        _ = casper_git_set_config_search_path(GIT_CONFIG_LEVEL_SYSTEM.rawValue, augmented)
    }

    /// `current` — a `:`-separated search path — with each of `directories` it does not
    /// already list appended to it. Unchanged when there is nothing to add, so applying
    /// it to its own result is a no-op.
    static func searchPath(_ current: String, adding directories: [String]) -> String {
        var listed = current.split(separator: ":").map(String.init)
        listed.append(contentsOf: directories.filter { !listed.contains($0) })
        return listed.joined(separator: ":")
    }

    /// libgit2's current system-level config search path (`:`-separated), or nil when
    /// it cannot be read.
    static func systemConfigSearchPath() -> String? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }  // before the call: dispose on the failure path too
        guard casper_git_get_config_search_path(GIT_CONFIG_LEVEL_SYSTEM.rawValue, &buffer) == 0,
              let contents = buffer.ptr else { return nil }
        return String(cString: contents)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
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

extension GitError: LocalizedError {
    /// What libgit2 said, so a caller that formats an arbitrary `Error` through
    /// `localizedDescription` shows the real cause rather than the synthesized
    /// "The operation couldn't be completed. (CasperGit.GitError error -1.)".
    public var errorDescription: String? { message }
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

/// Unwrap a pointer libgit2 promised on success. A non-negative return code with
/// a null out-pointer is a libgit2 contract violation, so surface it as an error
/// rather than force-unwrapping.
func requireNonNull<T>(_ value: T?, _ what: String) throws -> T {
    guard let value else {
        throw GitError(code: -1, message: "libgit2 returned success but a null \(what)")
    }
    return value
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
