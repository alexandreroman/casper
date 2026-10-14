import Foundation
import XCTest
@testable import CasperCore

final class ControlSocketTests: XCTestCase {
    private func tempSocketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("casper-control-test-\(UUID().uuidString.prefix(8)).sock")
    }

    func testServerReceivesCommandAndClientGetsResponse() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.onCommand = { command, reply in
            XCTAssertEqual(command.verb, .statusSet)
            XCTAssertEqual(command.state, "working")
            reply(.success(text: "ok"))
        }
        try server.start()
        defer { server.stop() }

        let response = try ControlSocketClient.send(
            ControlCommand(verb: .statusSet, workspace: "w", state: "working"),
            toSocketAt: path)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "ok")
    }

    func testMissingSocketThrowsControlSocketError() {
        XCTAssertThrowsError(
            try ControlSocketClient.send(
                ControlCommand(verb: .workspaceList), toSocketAt: tempSocketPath())
        ) { error in
            XCTAssertTrue(error is ControlSocketError)
        }
    }

    func testStaleSocketFileFailsFast() throws {
        let path = try staleSocketPath()
        defer { unlink(path) }

        let start = Date()
        XCTAssertThrowsError(
            try ControlSocketClient.send(ControlCommand(verb: .workspaceList), toSocketAt: path, timeout: 5)
        ) { error in
            XCTAssertTrue(error is ControlSocketError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testStaleSocketFileFailsFastEvenWhenRetriable() throws {
        let path = try staleSocketPath()
        defer { unlink(path) }

        let start = Date()
        XCTAssertThrowsError(
            try ControlSocketClient.send(
                ControlCommand(verb: .workspaceList), toSocketAt: path, timeout: 5, retriable: true)
        ) { error in
            XCTAssertTrue(error is ControlSocketError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testRetriableSendDoesNotRetryATimedOutAttempt() throws {
        let path = tempSocketPath()
        let server = ControlSocketServer(socketPath: path)
        server.onCommand = { _, _ in }  // accepts the request but never replies
        try server.start()
        defer { server.stop() }

        let start = Date()
        XCTAssertThrowsError(
            try ControlSocketClient.send(
                ControlCommand(verb: .workspaceList), toSocketAt: path, timeout: 0.3, retriable: true)
        ) { error in
            XCTAssertTrue(error is ControlSocketError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
    }

    /// The file a crashed app leaves behind: a socket bound and then closed
    /// without `unlink`, so the path exists but nothing listens on it.
    private func staleSocketPath() throws -> String {
        let path = tempSocketPath()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return path
    }
}
