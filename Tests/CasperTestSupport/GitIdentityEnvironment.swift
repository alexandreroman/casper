import Foundation
import XCTest

/// The environment variables libgit2's `git_signature_default_from_env` reads ahead of
/// (or, for `EMAIL`, behind) `user.name` / `user.email`.
public enum GitIdentityVariable: String, CaseIterable, Sendable {
    case authorName = "GIT_AUTHOR_NAME"
    case authorEmail = "GIT_AUTHOR_EMAIL"
    case authorDate = "GIT_AUTHOR_DATE"
    case committerName = "GIT_COMMITTER_NAME"
    case committerEmail = "GIT_COMMITTER_EMAIL"
    case committerDate = "GIT_COMMITTER_DATE"
    case email = "EMAIL"
}

extension XCTestCase {
    /// Give the Git identity variables exactly `values` for the rest of the test — every
    /// one not named is unset — and restore what the process had on teardown.
    ///
    /// The environment is process-wide, so a test asserting that a commit is *refused*
    /// calls this too, with no values: a developer shell exporting `GIT_AUTHOR_NAME`
    /// would otherwise hand the commit an identity and turn the refusal into a pass.
    public func setGitIdentityEnvironment(_ values: [GitIdentityVariable: String] = [:]) {
        var current: [GitIdentityVariable: String] = [:]
        for variable in GitIdentityVariable.allCases {
            if let value = getenv(variable.rawValue) {
                current[variable] = String(cString: value)
            }
        }
        let saved = current
        addTeardownBlock { Self.applyGitIdentityEnvironment(saved) }
        Self.applyGitIdentityEnvironment(values)
    }

    private static func applyGitIdentityEnvironment(_ values: [GitIdentityVariable: String]) {
        for variable in GitIdentityVariable.allCases {
            if let value = values[variable] {
                setenv(variable.rawValue, value, 1)
            } else {
                unsetenv(variable.rawValue)
            }
        }
    }
}
