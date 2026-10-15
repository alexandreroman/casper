import XCTest
import Foundation
import CasperCore
import CasperGhostty
import CasperTestSupport
@testable import CasperUI

@MainActor
final class LayoutActionHandlerTests: XCTestCase {
    func testHandlerForwardsLayoutActionsAndClaimsThem() throws {
        let dir = makeTemporaryDirectory(prefix: "casper-lah")
        let model = makeModel()
        model.addSpace(folderURL: dir, probe: { _ in nil })  // non-Git degenerate Space
        model.focusSurface(LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout)[0])

        let handler = LayoutActionHandler(model: model)
        XCTAssertTrue(handler.handle(.newSplit(.right)))   // claimed
        XCTAssertEqual(
            LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 2)
        XCTAssertFalse(handler.handle(.render))            // not a layout action
    }

    /// ⌘N is a libghostty keybind, so `.newWindow` is the only thing the keystroke can
    /// arrive as — `GhosttyCommandNRoutingTests` pins that half. This is the other
    /// half: the action has to reach "New Workspace…", or the shortcut is claimed from
    /// the main menu and then does nothing at all.
    ///
    /// The name prompt itself is substituted, the way `GhosttyClipboardRead.approveUntrusted`
    /// is: an `NSAlert` cannot run under XCTest. Cancelling is what the stand-in
    /// reports, so nothing is created.
    func testNewWindowOpensTheNewWorkspacePromptExactlyOnceAndClaimsTheAction() {
        let primary = Workspace(
            name: "main", worktreePath: "/tmp/primary", branch: "main",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: "/tmp/primary")))
        let space = Space(name: "repo", folderPath: "/tmp", isGitRepo: true, workspaces: [primary])
        let model = makeModel(spaces: [space], selecting: primary.id)
        var prompts = 0
        let prompted = expectation(description: "the new-workspace name is asked for")
        let original = AppModel.askNewWorkspaceName
        defer { AppModel.askNewWorkspaceName = original }
        AppModel.askNewWorkspaceName = {
            prompts += 1
            prompted.fulfill()
            return nil  // the user cancels
        }

        let handler = LayoutActionHandler(model: model)
        XCTAssertTrue(
            handler.handle(.newWindow),
            "an unclaimed .newWindow takes ⌘N away from the menu item without replacing it")
        XCTAssertEqual(prompts, 0, "the prompt must not run inside libghostty's key-processing tick")

        // The prompt is deliberately deferred off libghostty's key-processing tick, so
        // it lands on a later turn of the main run loop rather than inline.
        wait(for: [prompted], timeout: 2)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(model.spaces[0].workspaces.count, 1)
    }

    /// The prompt's `runModal()` must not be entered from inside a main-queue block:
    /// libdispatch never re-enters the main queue drain, so the queue would stay starved
    /// — `@MainActor` tasks, refreshes, AppKit's own focus handling — for as long as the
    /// prompt is up. The stand-in plays the modal's part: it spins a nested run loop and
    /// checks that a main-queue block queued meanwhile still gets to run.
    func testNewWindowOpensThePromptWhereTheMainQueueKeepsDraining() {
        let primary = Workspace(
            name: "main", worktreePath: "/tmp/primary", branch: "main",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: "/tmp/primary")))
        let space = Space(name: "repo", folderPath: "/tmp", isGitRepo: true, workspaces: [primary])
        let model = makeModel(spaces: [space], selecting: primary.id)
        let mainQueueBlockRan = Flag()
        let prompted = expectation(description: "the new-workspace name is asked for")
        let original = AppModel.askNewWorkspaceName
        defer { AppModel.askNewWorkspaceName = original }
        AppModel.askNewWorkspaceName = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { mainQueueBlockRan.value = true }
            }
            let deadline = Date().addingTimeInterval(1)
            while !mainQueueBlockRan.value, Date() < deadline {
                _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
            }
            prompted.fulfill()
            return nil  // the user cancels
        }

        XCTAssertTrue(LayoutActionHandler(model: model).handle(.newWindow))

        wait(for: [prompted], timeout: 3)
        XCTAssertTrue(
            mainQueueBlockRan.value,
            "the prompt runs inside a main-queue drain, which starves the main queue while it is up")
    }

    /// With no Git Space there is nowhere to create a workspace — the menu item is
    /// disabled — so ⌘N in a terminal asks nothing either, yet stays claimed: falling
    /// through would hand the keystroke to libghostty's own "new window".
    func testNewWindowWithoutAGitSpaceAsksNothingButStillClaimsTheAction() {
        let dir = makeTemporaryDirectory(prefix: "casper-lah")
        let model = makeModel()
        model.addSpace(folderURL: dir, probe: { _ in nil })  // non-Git degenerate Space
        let prompted = expectation(description: "no name prompt")
        prompted.isInverted = true
        let original = AppModel.askNewWorkspaceName
        defer { AppModel.askNewWorkspaceName = original }
        AppModel.askNewWorkspaceName = {
            prompted.fulfill()
            return nil
        }

        XCTAssertTrue(LayoutActionHandler(model: model).handle(.newWindow))
        wait(for: [prompted], timeout: 0.5)
    }
}

/// A flag a main-queue block can set and the test can read back.
@MainActor
private final class Flag {
    var value = false
}
