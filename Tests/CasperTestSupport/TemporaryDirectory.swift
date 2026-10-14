import Foundation
import XCTest

extension XCTestCase {
    /// A fresh temp directory on disk, removed after the test. `prefix` only makes
    /// a stranded directory traceable back to the suite that made it.
    ///
    /// It sits one level inside a container that teardown removes, because Casper
    /// puts a linked worktree *beside* its repository: deleting the repo directory
    /// alone would leave every worktree a test created behind.
    public func makeTemporaryDirectory(prefix: String = "casper-test") -> URL {
        let name = "\(prefix)-\(UUID().uuidString)"
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let dir = container.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        return dir
    }
}
