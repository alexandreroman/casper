import CasperGit
import XCTest

@testable import CasperUI

/// A `casper diff open <file>` request is one-shot: the diff view hands it back
/// once it is settled, so a remount — the view unmounts on collapse, on a switch
/// to the Browser tab and on a workspace switch — cannot scroll the reader back
/// to it, and a file that only changes later cannot pull the view there.
@MainActor
final class DiffScrollTargetTests: XCTestCase {
    private func file(_ path: String) -> GitDiffFile {
        diffFile(path, lines: [])
    }

    func testConsumingTheTargetClearsIt() throws {
        let (model, workspace) = makeSeededModel()
        model.requestDiffScroll(workspaceID: workspace.id, file: "a.swift")
        let target = try XCTUnwrap(model.diffScrollTarget)

        model.consumeDiffScrollTarget(target)

        XCTAssertNil(model.diffScrollTarget)
    }

    /// The view settles the target it read; a request landing in between is a new
    /// one and must survive.
    func testConsumingAStaleTargetLeavesTheNewerOneInPlace() throws {
        let (model, workspace) = makeSeededModel()
        model.requestDiffScroll(workspaceID: workspace.id, file: "a.swift")
        let stale = try XCTUnwrap(model.diffScrollTarget)
        model.requestDiffScroll(workspaceID: workspace.id, file: "a.swift")
        let newer = try XCTUnwrap(model.diffScrollTarget)

        model.consumeDiffScrollTarget(stale)

        XCTAssertEqual(model.diffScrollTarget, newer)
    }

    /// The request bumps the diff revision, so the view computes a diff that
    /// reflects the disk as of the request rather than settling against an older
    /// one that predates the file's change.
    func testARequestBumpsTheDiffRevisionItRecords() throws {
        let (model, workspace) = makeSeededModel()
        let before = model.diffRevision

        model.requestDiffScroll(workspaceID: workspace.id, file: "a.swift")

        XCTAssertEqual(model.diffRevision, before + 1)
        XCTAssertEqual(model.diffScrollTarget?.diffRevision, model.diffRevision)
    }

    func testAFreshDiffLackingTheFileSettlesTheTarget() {
        let target = AppModel.DiffScrollTarget(workspaceID: UUID(), file: "README.md", diffRevision: 3)

        XCTAssertTrue(target.isUnreachable(inDiffListing: [file("a.swift")], computedAt: 3))
        XCTAssertTrue(target.isUnreachable(inDiffListing: [], computedAt: 4))
        // No diff at all — not Git-backed, or the repository couldn't be read.
        XCTAssertTrue(target.isUnreachable(inDiffListing: nil, computedAt: 3))
    }

    /// Exact ids only: an unchanged root `README.md` never resolves to a changed
    /// `docs/README.md`.
    func testANestedFileOfTheSameNameDoesNotHoldTheTarget() {
        let target = AppModel.DiffScrollTarget(workspaceID: UUID(), file: "README.md", diffRevision: 3)

        XCTAssertTrue(target.isUnreachable(inDiffListing: [file("docs/README.md")], computedAt: 3))
    }

    func testADiffListingTheFileKeepsTheTargetForTheScroll() {
        let target = AppModel.DiffScrollTarget(workspaceID: UUID(), file: "a.swift", diffRevision: 3)

        XCTAssertFalse(target.isUnreachable(inDiffListing: [file("a.swift")], computedAt: 3))
    }

    /// A diff older than the request may predate the file's change, so it settles
    /// nothing: the fresh one is on its way.
    func testAnOlderDiffLackingTheFileKeepsTheTarget() {
        let target = AppModel.DiffScrollTarget(workspaceID: UUID(), file: "a.swift", diffRevision: 3)

        XCTAssertFalse(target.isUnreachable(inDiffListing: [], computedAt: 2))
    }
}
