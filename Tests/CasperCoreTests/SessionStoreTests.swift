import XCTest
@testable import CasperCore

final class SessionStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
    }

    func testLoadMissingFileReturnsEmptySession() throws {
        let store = SessionStore(fileURL: tempFileURL())
        XCTAssertEqual(try store.load(), Session())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)

        let session = Session(workspaces: [
            Workspace(
                name: "w", repoPath: "/r", worktreePath: "/r/w", branch: "b",
                portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
            )
        ])
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
    }

    func testDefaultURLIsUnderApplicationSupportCasper() throws {
        let url = try SessionStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "session.json")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Casper")
    }
}
