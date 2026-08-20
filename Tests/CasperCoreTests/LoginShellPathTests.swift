import Foundation
import XCTest
@testable import CasperCore

/// Every test here drives `LoginShellPath` through its injected runner, so the
/// suite never spawns a real login shell (which would source the developer's
/// own profile and make the results machine-dependent).
final class LoginShellPathTests: XCTestCase {
    /// The runner is `@Sendable`, so a stub needs a `Sendable` place to record
    /// its calls — a lock-protected box, like `LoginShellPath`'s own storage.
    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [String] = []

        var callCount: Int { lock.withLock { commands.count } }
        var lastCommand: String? { lock.withLock { commands.last } }

        func record(_ command: String) {
            lock.withLock { commands.append(command) }
        }
    }

    override func setUp() {
        super.setUp()
        LoginShellPath.resetForTesting()
    }

    override func tearDown() {
        // The cache and the runner are process-wide, so hand them back clean.
        LoginShellPath.resetForTesting()
        super.tearDown()
    }

    /// Installs a stub runner that always returns `output`, and returns the
    /// recorder tracking how often (and with what) it was called.
    @discardableResult
    private func stubRunner(returning output: String?) -> CallRecorder {
        let recorder = CallRecorder()
        LoginShellPath.runner = { command in
            recorder.record(command)
            return output
        }
        return recorder
    }

    func testResolvesTheSingleLineOutputOfWhich() {
        let recorder = stubRunner(returning: "/opt/homebrew/bin/code\n")

        XCTAssertEqual(LoginShellPath.resolve("code"), "/opt/homebrew/bin/code")
        XCTAssertEqual(recorder.lastCommand, "code")
    }

    func testTakesTheLastNonEmptyLineSoProfileBannersAreIgnored() {
        // A login shell sources the user's profile, which routinely prints
        // banner text to stdout before `which` runs. The path is what comes
        // last, not the whole blob.
        stubRunner(returning: """
        Homebrew shellenv applied
        nvm: now using node v22.3.0

        /Users/dev/.local/bin/idea

        """)

        XCTAssertEqual(LoginShellPath.resolve("idea"), "/Users/dev/.local/bin/idea")
    }

    func testTrimsWhitespaceAroundTheResolvedPath() {
        stubRunner(returning: "  \t/usr/bin/xed \n")

        XCTAssertEqual(LoginShellPath.resolve("xed"), "/usr/bin/xed")
    }

    func testEmptyOutputResolvesToNil() {
        stubRunner(returning: "")

        XCTAssertNil(LoginShellPath.resolve("missing"))
    }

    func testWhitespaceOnlyOutputResolvesToNil() {
        stubRunner(returning: "\n   \n\t\n")

        XCTAssertNil(LoginShellPath.resolve("blank"))
    }

    func testAFailedLookupResolvesToNil() {
        stubRunner(returning: nil)

        XCTAssertNil(LoginShellPath.resolve("broken"))
    }

    func testResolvesAGivenCommandAtMostOnce() {
        let recorder = stubRunner(returning: "/opt/homebrew/bin/code\n")

        XCTAssertEqual(LoginShellPath.resolve("code"), "/opt/homebrew/bin/code")
        XCTAssertEqual(LoginShellPath.resolve("code"), "/opt/homebrew/bin/code")

        XCTAssertEqual(recorder.callCount, 1, "the second resolve must come from the cache")
    }

    func testCachesAFailedLookupToo() {
        // The expensive case: a command that resolves to nothing still paid the
        // full login-shell cost, so it must not be looked up again.
        let recorder = stubRunner(returning: "")

        XCTAssertNil(LoginShellPath.resolve("missing"))
        XCTAssertNil(LoginShellPath.resolve("missing"))

        XCTAssertEqual(recorder.callCount, 1, "an unresolvable command must stay cached")
    }
}
