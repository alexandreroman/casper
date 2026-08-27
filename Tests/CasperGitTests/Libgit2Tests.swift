import XCTest
import Clibgit2
@testable import CasperGit

final class Libgit2Tests: XCTestCase {
    func testEnsureInitIsIdempotent() {
        Libgit2.ensureInit()
        Libgit2.ensureInit()  // must not crash or over-init

        // After a double init, a real libgit2 call must still work.
        var major: Int32 = 0
        var minor: Int32 = 0
        var rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        XCTAssertGreaterThanOrEqual(major, 1)
    }

    func testEnsureInitPutsAppleGitSystemConfigOnTheSearchPath() {
        Libgit2.ensureInit()
        let afterInit = Libgit2.systemConfigSearchPath()

        let searched = Set((afterInit ?? "").split(separator: ":").map(String.init))
        // libgit2 always searches somewhere of its own (`/etc`, a package prefix), so an
        // empty path would mean the augmentation clobbered it instead of extending it.
        XCTAssertFalse(searched.isEmpty)
        // Machine-dependent by nature: a machine with neither Xcode nor the Command Line
        // Tools installed discovers nothing, and then there is nothing to have been added.
        for directory in Libgit2.appleGitSystemConfigDirectories {
            XCTAssertTrue(searched.contains(directory), "\(directory) is not searched")
        }

        // Initialization happens once, and running the augmentation again on top of what
        // it left behind changes nothing either.
        Libgit2.ensureInit()
        Libgit2.addAppleGitSystemConfigDirectories()
        XCTAssertEqual(Libgit2.systemConfigSearchPath(), afterInit)
    }

    /// The user-visible payoff of the augmentation, as opposed to the search-path
    /// string the test above pins: a repository libgit2 initializes is born on the
    /// branch Apple's system `gitconfig` names, the way `git init` in the terminal is,
    /// instead of on libgit2's built-in `master`.
    ///
    /// The expectation is read out of that file rather than hardcoded to `main`: the
    /// name is the machine's configuration, not Casper's.
    func testAFreshRepositoryIsBornOnTheAppleSystemConfigDefaultBranch() throws {
        Libgit2.ensureInit()
        let appleDirectories = Libgit2.appleGitSystemConfigDirectories
        let appleConfig = appleDirectories
            .map { $0 + "/gitconfig" }
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let appleConfig else {
            throw XCTSkip("no Apple git-core gitconfig on this machine")
        }
        // The augmentation *appends*, and libgit2 resolves a config level to the first
        // existing file along the search path — so any other directory it searches that
        // holds a `gitconfig` answers instead, and there is nothing here to observe.
        let searched = (Libgit2.systemConfigSearchPath() ?? "").split(separator: ":").map(String.init)
        let earlier = searched.filter { !appleDirectories.contains($0) }
        try XCTSkipIf(
            earlier.contains { FileManager.default.fileExists(atPath: $0 + "/gitconfig") },
            "another gitconfig answers the system level first, so Apple's is never read")
        guard let expected = try defaultBranch(configuredIn: appleConfig) else {
            throw XCTSkip("Apple's gitconfig sets no init.defaultBranch on this machine")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-libgit2-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repository = try Repository.initialize(atPath: directory.path)

        XCTAssertEqual(try repository.headBranchName(), expected)
    }

    /// `init.defaultBranch` as the config file at `path` sets it, or nil when it does
    /// not. Read from that one file, never through libgit2's resolved configuration,
    /// which is the thing under test.
    private func defaultBranch(configuredIn path: String) throws -> String? {
        var config: OpaquePointer?
        defer { git_config_free(config) }  // before the call: free on the throw path too
        try gitCheck(git_config_open_ondisk(&config, path))
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        let code = git_config_get_string_buf(&buffer, config, "init.defaultBranch")
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try gitCheck(code)
        return buffer.ptr.map { String(cString: $0) }
    }

    func testSearchPathAugmentationAppendsOnlyWhatIsMissing() {
        let augmented = Libgit2.searchPath("/etc:/opt/homebrew/etc", adding: ["/etc", "/xcode"])

        // Order matters: what libgit2 already searched keeps its precedence.
        XCTAssertEqual(augmented, "/etc:/opt/homebrew/etc:/xcode")
        XCTAssertEqual(Libgit2.searchPath(augmented, adding: ["/etc", "/xcode"]), augmented)
    }

    func testSearchPathAugmentationLeavesAPathAloneWhenThereIsNothingToAdd() {
        // The machine with neither Xcode nor the Command Line Tools: nothing is
        // discovered, and libgit2's own search path must stand untouched.
        XCTAssertEqual(Libgit2.searchPath("/etc:/opt/homebrew/etc", adding: []), "/etc:/opt/homebrew/etc")
    }

    func testGitCheckThrowsOnNegativeCode() {
        // Force a known failure: open a non-existent repo.
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        let code = git_repository_open(&repo, "/nonexistent/casper/repo")
        XCTAssertLessThan(code, 0)
        XCTAssertThrowsError(try gitCheck(code)) { error in
            guard let gitError = error as? GitError else {
                return XCTFail("expected GitError, got \(error)")
            }
            XCTAssertEqual(gitError.code, code)
            XCTAssertFalse(gitError.message.isEmpty)
        }
    }

    func testGitCheckReturnsCodeOnSuccess() throws {
        XCTAssertEqual(try gitCheck(0), 0)
    }
}
