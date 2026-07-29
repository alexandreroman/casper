import Foundation
import XCTest
@testable import CasperCore

final class SessionStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
    }

    // `isGitRepo` is intentionally not persisted (it is resolved at runtime), so
    // the fixture uses `isGitRepo: false` for round-trip equality to hold.
    private func makeSampleSession() -> Session {
        Session(spaces: [
            Space(name: "r", folderPath: "/r", isGitRepo: false, workspaces: [
                Workspace(
                    name: "w", worktreePath: "/r/w", branch: "b",
                    portBase: 40000,
                    layout: .leaf(Surface(kind: .terminal(cwd: "/r/w"))))
            ])
        ])
    }

    func testLoadMissingFileReturnsEmptySession() throws {
        let store = SessionStore(fileURL: tempFileURL())
        XCTAssertEqual(try store.load(), Session())
    }

    func testSaveThenLoadRoundTrips() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)

        let session = makeSampleSession()
        try store.write(store.encode(session))
        XCTAssertEqual(try store.load(), session)
    }

    func testDefaultURLIsUnderApplicationSupportCasper() throws {
        let url = try SessionStore.defaultURL()
        XCTAssertEqual(url.lastPathComponent, "session.json")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "Casper")
    }

    func testLoadCorruptFileSelfHealsAndBacksItUp() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ this is not valid session json".utf8)
        try garbage.write(to: url)

        let store = SessionStore(fileURL: url)
        // A decode failure must self-heal into an empty session rather than throw.
        XCTAssertEqual(try store.load(), Session())

        // The offending file is moved aside for diagnostics, not left in place.
        let backupURL = url.appendingPathExtension("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage)
    }

    func testLoadCorruptFileReplacesPriorBackup() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backupURL = url.appendingPathExtension("corrupt")
        try Data("stale backup".utf8).write(to: backupURL)
        let garbage = Data("still not json".utf8)
        try garbage.write(to: url)

        let store = SessionStore(fileURL: url)
        XCTAssertEqual(try store.load(), Session())
        // The stale backup is replaced by the newly corrupt file.
        XCTAssertEqual(try Data(contentsOf: backupURL), garbage)
    }

    func testUI1FormatSessionIsRejectedAndBackedUp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.json")
        let legacy = """
        { "workspaces": [ { "id": "\(UUID().uuidString)", "name": "w",
          "repoPath": "/r", "worktreePath": "/r", "branch": "main",
          "agentState": "idle", "todos": [], "pendingNotification": false,
          "portBase": 40000,
          "layout": { "tabGroup": { "surfaces": [], "activeIndex": 0 } } } ] }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let store = SessionStore(fileURL: url)
        let loaded = try store.load()
        XCTAssertTrue(loaded.spaces.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("corrupt").path))
    }

    func testSaveDoesNotPrettyPrint() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)

        let session = makeSampleSession()
        try store.write(store.encode(session))

        // Pretty-printed output indents with "\n  "; a compact encode has no
        // newline byte at all.
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.contains(UInt8(ascii: "\n")))

        XCTAssertEqual(try store.load(), session)
    }

    func testDefaultURLUsesSessionLayoutFileName() throws {
        let base = try SessionStore.defaultURL(session: SessionIdentity(name: "dev")!)
        XCTAssertEqual(base.lastPathComponent, "session-dev.json")
        let dflt = try SessionStore.defaultURL()
        XCTAssertEqual(dflt.lastPathComponent, "session.json") // backward-compatible
    }
}
