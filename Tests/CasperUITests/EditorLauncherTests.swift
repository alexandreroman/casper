import XCTest
import CasperCore
@testable import CasperUI

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

    func testLaunchThrowsShimNotFoundForAnUnresolvableCommand() {
        // Whether or not VS Code's `code` shim happens to be on this test
        // machine's PATH, launching into a directory that doesn't exist must
        // throw: either `resolveCLIPath` fails to resolve the shim
        // (`.shimNotFound`), or it resolves and `Process.run()` itself throws
        // because `currentDirectoryURL` doesn't exist. Either way, this
        // proves `launch()` propagates failure rather than swallowing it.
        XCTAssertThrowsError(try EditorLauncher.launch(.vscode, at: "/nonexistent-\(UUID().uuidString)"))
    }
}
