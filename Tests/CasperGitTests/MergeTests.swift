import Foundation
import XCTest
import Clibgit2
import CasperTestSupport
@testable import CasperGit

final class MergeTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = makeTemporaryDirectory(prefix: "casper-merge")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    }

    /// The tip commit OID (hex string) of local branch `name`.
    private func tipOID(_ repo: Repository, branch name: String) throws -> String {
        var ref: OpaquePointer?
        try gitCheck(git_branch_lookup(&ref, repo.pointer, name, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        var commit: OpaquePointer?
        try gitCheck(git_reference_peel(&commit, ref, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        var buf = [Int8](repeating: 0, count: 41)
        git_oid_tostr(&buf, 41, git_object_id(commit))
        let oidBytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: oidBytes, as: UTF8.self)
    }

    func testMergeAlreadyUpToDateWritesNothing() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let beforeOID = try tipOID(repo, branch: main)

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge")

        XCTAssertEqual(outcome, .upToDate)
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    func testMergeWithoutCommitterIdentityThrowsAndWritesNothing() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "new\n", message: "add feature")
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "", email: "")
        setGitIdentityEnvironment()
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertNotNil(identityError, "got: \(error)")
            XCTAssertFalse(identityError?.detail.isEmpty ?? true, "libgit2's own message is kept")
            XCTAssertEqual(identityError?.environmentVariables, [], "the configuration is to blame")
            XCTAssertEqual(identityError?.configurationAtFault, true, "a blank setting is at fault")
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    /// A set variable shadows the configuration even when blank, so `git config` cannot
    /// fix the refusal: the error names the variables to blame instead.
    func testMergeRefusalBlamesBlankIdentityVariables() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        setGitIdentityEnvironment([.authorName: "", .authorEmail: "author@env.example", .committerEmail: "  "])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            XCTAssertEqual(
                (error as? MissingCommitterIdentityError)?.environmentVariables,
                ["GIT_AUTHOR_NAME", "GIT_COMMITTER_EMAIL"], "got: \(error)")
        }
    }

    func testMergeRefusalBlamesAnUnparsableDateVariable() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        setGitIdentityEnvironment([.authorName: "Env Author", .committerDate: "zzz"])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertEqual(identityError?.environmentVariables, ["GIT_COMMITTER_DATE"], "got: \(error)")
            XCTAssertEqual(identityError?.detail, "unparsable date")
        }
    }

    /// Only the side that fails on its date is blamed: a valid date beside an unparsable
    /// one is never named, whichever side libgit2 reaches first.
    func testMergeRefusalBlamesOnlyTheUnparsableOfTwoDateVariables() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        let validDate = "2026-01-01 00:00:00 +0000"
        let cases: [(dates: [GitIdentityVariable: String], blamed: String)] = [
            ([.authorDate: "zzz", .committerDate: validDate], "GIT_AUTHOR_DATE"),
            ([.authorDate: validDate, .committerDate: "zzz"], "GIT_COMMITTER_DATE"),
        ]
        for (dates, blamed) in cases {
            setGitIdentityEnvironment(dates)

            XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
                let identityError = error as? MissingCommitterIdentityError
                XCTAssertEqual(identityError?.environmentVariables, [blamed], "got: \(error)")
                XCTAssertEqual(identityError?.detail, "unparsable date")
            }
        }
    }

    /// With no `user.email` anywhere, libgit2 falls back on `EMAIL` but leaves its "not
    /// found" error recorded, so a date that then fails to parse records an error that is
    /// not its own. The date is still the one to blame.
    func testMergeRefusalBlamesAnUnparsableDateAfterTheEmailFallback() throws {
        let (_, main) = try repositoryWithAFeatureCommit()
        isolateFromTheMachineGitConfiguration()
        let repo = try Repository.open(atPath: repoDir.path)
        try removeConfiguredEmail(repo)
        setGitIdentityEnvironment([.email: "fallback@env.example", .committerDate: "zzz"])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertEqual(identityError?.environmentVariables, ["GIT_COMMITTER_DATE"], "got: \(error)")
            XCTAssertEqual(identityError?.detail, "unparsable date")
            XCTAssertEqual(identityError?.configurationAtFault, false, "EMAIL stands in for user.email")
        }
    }

    /// A blank variable and a setting missing from the configuration are both to blame:
    /// the error says so, whichever of the two libgit2 met first.
    func testMergeRefusalReportsAMissingSettingBesideABlankVariable() throws {
        let (_, main) = try repositoryWithAFeatureCommit()
        isolateFromTheMachineGitConfiguration()
        let repo = try Repository.open(atPath: repoDir.path)
        try removeConfiguredEmail(repo)
        setGitIdentityEnvironment([.authorName: ""])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertEqual(identityError?.environmentVariables, ["GIT_AUTHOR_NAME"], "got: \(error)")
            XCTAssertEqual(identityError?.configurationAtFault, true, "got: \(error)")
        }
    }

    /// A blank `user.name` fails the author side, which no variable shapes, while the
    /// committer side fails on its date: the configuration is to blame beside the date.
    func testMergeRefusalReportsABlankSettingBesideAnUnparsableDate() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "", email: "config@example.com")
        setGitIdentityEnvironment([.committerDate: "zzz"])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertEqual(identityError?.environmentVariables, ["GIT_COMMITTER_DATE"], "got: \(error)")
            XCTAssertEqual(identityError?.configurationAtFault, true, "got: \(error)")
        }
    }

    /// A blank variable fails the author side, and a blank `user.email` the committer
    /// side, which no variable shapes: the configuration is to blame beside the variable.
    func testMergeRefusalReportsABlankSettingBesideABlankVariable() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "Config Name", email: "")
        setGitIdentityEnvironment([.authorName: ""])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertEqual(identityError?.environmentVariables, ["GIT_AUTHOR_NAME"], "got: \(error)")
            XCTAssertEqual(identityError?.configurationAtFault, true, "got: \(error)")
        }
    }

    /// Valid variables set beside a broken configuration take none of the blame: there,
    /// `git config` is the fix.
    func testMergeRefusalBlamesNoValidIdentityVariable() throws {
        let (repo, main) = try repositoryWithAFeatureCommit()
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "Config Name", email: "")
        setGitIdentityEnvironment([
            .authorName: "Env Author", .committerName: "Env Committer",
            .authorDate: "2026-01-01 00:00:00 +0000",
        ])

        XCTAssertThrowsError(try repo.mergeBranchHeadless("feature", into: main, message: "merge")) { error in
            let identityError = error as? MissingCommitterIdentityError
            XCTAssertNotNil(identityError, "got: \(error)")
            XCTAssertEqual(identityError?.environmentVariables, [])
        }
    }

    /// A repository whose `feature` branch holds one commit its base lacks, so merging it
    /// writes a commit; returns the repository and its base branch.
    private func repositoryWithAFeatureCommit() throws -> (Repository, String) {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "new\n", message: "add feature")
        return (repo, main)
    }

    /// Point libgit2's machine-wide configuration levels at an empty directory for the
    /// rest of the test, so that a setting the repository lacks is missing outright rather
    /// than read from the developer's own Git configuration. Only a repository opened
    /// afterwards sees the change: an open one has already loaded its configuration.
    private func isolateFromTheMachineGitConfiguration() {
        let emptyDirectory = root.appendingPathComponent("no-git-config")
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true))
        let levels = [
            GIT_CONFIG_LEVEL_PROGRAMDATA, GIT_CONFIG_LEVEL_SYSTEM, GIT_CONFIG_LEVEL_XDG, GIT_CONFIG_LEVEL_GLOBAL,
        ]
        for level in levels.map(\.rawValue) {
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            guard casper_git_get_config_search_path(level, &buffer) == 0, let contents = buffer.ptr else {
                XCTFail("cannot read libgit2's config search path for level \(level)")
                continue
            }
            let saved = String(cString: contents)
            addTeardownBlock { _ = casper_git_set_config_search_path(level, saved) }
            XCTAssertEqual(casper_git_set_config_search_path(level, emptyDirectory.path), 0)
        }
    }

    /// Delete `user.email` from `repo`'s own configuration.
    private func removeConfiguredEmail(_ repo: Repository) throws {
        var config: OpaquePointer?
        try gitCheck(git_repository_config(&config, repo.pointer))
        defer { git_config_free(config) }
        try gitCheck(git_config_delete_entry(config, "user.email"))
    }

    /// The environment names an identity the configuration lacks: the author comes from
    /// `GIT_AUTHOR_*` and the committer from `GIT_COMMITTER_*`, each on its own.
    func testMergeTakesItsIdentityFromTheEnvironmentWhenTheConfigHasNone() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "new\n", message: "add feature")
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "", email: "")
        setGitIdentityEnvironment([
            .authorName: "Env Author", .authorEmail: "author@env.example",
            .committerName: "Env Committer", .committerEmail: "committer@env.example",
        ])

        XCTAssertEqual(try repo.mergeBranchHeadless("feature", into: main, message: "merge"), .merged)

        let identities = try GitFixture.headCommitIdentities(atPath: repoDir.path)
        XCTAssertEqual(identities.author, "Env Author <author@env.example>")
        XCTAssertEqual(identities.committer, "Env Committer <committer@env.example>")
    }

    /// An up-to-date merge commits nothing, so it needs no identity.
    func testMergeAlreadyUpToDateNeedsNoCommitterIdentity() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.configureIdentity(atPath: repoDir.path, name: "", email: "")
        setGitIdentityEnvironment()

        XCTAssertEqual(try repo.mergeBranchHeadless("feature", into: main, message: "merge"), .upToDate)
    }

    func testMergeFastForwardableHistoryCreatesMergeCommit() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "new\n", message: "add feature")

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")

        guard case .merged = outcome else { return XCTFail("expected a merge commit") }
        // Always a merge commit (--no-ff), never a checkout: the tree carries the new
        // file even though the target's working directory is untouched.
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))
    }

    func testMergeDivergentHistoryAutoMerges() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "from feature\n",
            message: "add feature file")
        try GitFixture.commit(
            atPath: repoDir.path, file: "main.txt", contents: "from main\n", message: "add main file")

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")

        guard case .merged = outcome else { return XCTFail("expected a merge commit") }
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "from feature\n")
        XCTAssertEqual(try repo.fileTextAtHead(path: "main.txt"), "from main\n")
    }

    func testMergeConflictingHistoryThrowsAndWritesNothing() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "README.md", contents: "from feature\n",
            message: "feature edits readme")
        try GitFixture.commit(
            atPath: repoDir.path, file: "README.md", contents: "from main\n", message: "main edits readme")
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")
        ) { error in
            XCTAssertTrue(error is MergeConflictError)
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    func testMergeUnrelatedHistoriesThrowsAGitErrorSayingSo() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        try makeOrphanBranch(repo, name: "orphan")
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("orphan", into: main, message: "merge orphan")
        ) { error in
            let gitError = error as? GitError
            XCTAssertTrue(
                gitError?.message.contains("unrelated histories") == true,
                "expected an unrelated-histories GitError, got \(error)")
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    /// Point branch `name` at a fresh *root* commit (no parents) reusing HEAD's tree,
    /// so it shares no ancestor with the default branch — `git_merge_base` then
    /// reports GIT_ENOTFOUND.
    private func makeOrphanBranch(_ repo: Repository, name: String) throws {
        var headRef: OpaquePointer?
        try gitCheck(git_repository_head(&headRef, repo.pointer))
        defer { git_reference_free(headRef) }
        var tree: OpaquePointer?
        try gitCheck(git_reference_peel(&tree, headRef, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        var commitOid = git_oid()
        try gitCheck(git_commit_create(
            &commitOid, repo.pointer, "refs/heads/\(name)",
            signature, signature, nil, "Unrelated root commit", tree, 0, nil))
    }

    func testMergeMissingTargetBranchThrows() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: "ghost-branch", message: "merge"))
    }

    func testForceCheckoutHeadSyncsWorkdirToNewHead() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        try GitFixture.commit(
            atPath: wtInfo.path, file: "feature.txt", contents: "new\n", message: "add feature")

        _ = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")
        // Confirms the precondition: right after a headless merge, the target's
        // working directory has NOT picked up the new file yet.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))

        try repo.forceCheckoutHead()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))
    }
}
