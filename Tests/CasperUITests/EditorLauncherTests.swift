import XCTest
import CasperCore
@testable import CasperUI

/// `@MainActor` because `EditorLauncher` is: it memoizes icon and CLI-path
/// lookups in shared state, isolated to the actor every caller already runs on.
@MainActor
final class EditorLauncherTests: XCTestCase {
    /// `detectInstalled()` depends on what's actually installed on the machine
    /// running the test, so this only checks the invariant that holds
    /// regardless of environment: the result is a duplicate-free subsequence
    /// of `EditorKind.priorityOrder`, in the same relative order.
    func testDetectInstalledIsOrderedSubsequenceOfPriorityOrder() {
        let detected = EditorLauncher.detectInstalled()
        XCTAssertEqual(detected, Set(detected).sorted { l, r in
            EditorKind.priorityOrder.firstIndex(of: l)! < EditorKind.priorityOrder.firstIndex(of: r)!
        })
        for kind in detected {
            XCTAssertTrue(EditorKind.priorityOrder.contains(kind))
        }
    }

    /// `launch(_:at:)` now falls back to an async, fire-and-forget bundle
    /// open when the CLI shim is missing, so it no longer throws
    /// synchronously just because the target directory doesn't exist. The
    /// contract that still holds: launching throws if and only if the
    /// editor isn't actually installed (per `detectInstalled()`) on the
    /// machine running the test.
    func testLaunchThrowsForAnEditorNotInstalledOnThisMachine() throws {
        let detected = EditorLauncher.detectInstalled()
        guard let notInstalled = EditorKind.allCases.first(where: { !detected.contains($0) }) else {
            throw XCTSkip("all three editors are installed on this machine")
        }
        XCTAssertThrowsError(try EditorLauncher.launch(notInstalled, at: "/tmp"))
    }
}
