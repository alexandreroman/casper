#if DEBUG
import AppKit
import CasperCore
import CoreGraphics

/// A snapshot description of one live surface, decoupling `DebugServer` from the
/// concrete AppKit view. The provider builds these on the main thread.
@MainActor
public struct DebugSurfaceHandle {
    public let title: String
    public let workingDirectory: String?
    public let focused: Bool
    public let readText: (_ scrollback: Bool) -> String?
    public let sendText: (_ text: String) -> Void
    public let columnsRows: () -> (Int, Int)
    public let window: NSWindow?

    public init(
        title: String, workingDirectory: String?, focused: Bool,
        readText: @escaping (_ scrollback: Bool) -> String?,
        sendText: @escaping (_ text: String) -> Void,
        columnsRows: @escaping () -> (Int, Int),
        window: NSWindow?
    ) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.focused = focused
        self.readText = readText
        self.sendText = sendText
        self.columnsRows = columnsRows
        self.window = window
    }
}

/// Supplies the current set of surfaces to the debug server. `GhosttyDemo`
/// conforms today; the Plan 5 app conforms later.
@MainActor
public protocol DebugSurfaceProvider: AnyObject {
    func debugSurfaces() -> [DebugSurfaceHandle]
}

/// Binds the debug socket and dispatches `DebugCommand`s against the provider's
/// surfaces on the main thread. Debug builds only.
@MainActor
public final class DebugServer {
    private let server: DebugSocketServer
    private weak var provider: (any DebugSurfaceProvider)?

    public init(socketPath: String, provider: any DebugSurfaceProvider) {
        self.provider = provider
        self.server = DebugSocketServer(socketPath: socketPath)
        self.server.onCommand = { [weak self] command, reply in
            // onCommand runs on the socket queue; surface work is main-thread only.
            Task { @MainActor in
                let response = self?.handle(command) ?? .failure("server deallocated")
                reply(response)
            }
        }
    }

    public func start() throws {
        try server.start()
        CasperLog.debug.debug("debug server listening")
    }

    public func stop() { server.stop() }

    private func handle(_ command: DebugCommand) -> DebugResponse {
        CasperLog.debug.debug("debug command: \(command.verb.rawValue, privacy: .public)")
        let response = resolve(command)
        if !response.ok {
            let reason = response.error ?? ""
            CasperLog.debug.debug(
                "debug command failed: \(command.verb.rawValue, privacy: .public) — \(reason, privacy: .public)")
        }
        return response
    }

    private func resolve(_ command: DebugCommand) -> DebugResponse {
        let surfaces = provider?.debugSurfaces() ?? []

        switch command.verb {
        case .dumpState:
            let entries = surfaces.map { handle -> DebugState.Surface in
                let (columns, rows) = handle.columnsRows()
                return DebugState.Surface(
                    title: handle.title, workingDirectory: handle.workingDirectory,
                    columns: columns, rows: rows, focused: handle.focused)
            }
            return .success(state: DebugState(surfaces: entries))

        case .readText:
            guard let target = focusedOrFirst(surfaces) else { return .failure("no surface") }
            guard let text = target.readText(command.scrollback ?? false) else {
                return .failure("read-text unavailable")
            }
            return .success(text: text)

        case .sendText:
            guard let target = focusedOrFirst(surfaces) else { return .failure("no surface") }
            guard let text = command.text else { return .failure("missing text") }
            target.sendText(command.enter == true ? text + "\n" : text)
            return .success()

        case .screenshot:
            guard let path = command.path else { return .failure("missing path") }
            guard let window = focusedOrFirst(surfaces)?.window else { return .failure("no window") }
            return screenshot(window: window, to: path)
        }
    }

    private func focusedOrFirst(_ surfaces: [DebugSurfaceHandle]) -> DebugSurfaceHandle? {
        surfaces.first(where: { $0.focused }) ?? surfaces.first
    }

    private func screenshot(window: NSWindow, to path: String) -> DebugResponse {
        let windowID = CGWindowID(window.windowNumber)
        // CGWindowListCreateImage is deprecated on macOS 14 but remains the only
        // reliable way to capture a Metal-rendered window's actual pixels; this
        // path is debug-only and never ships in release.
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return .failure("window capture failed")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return .failure("PNG encoding failed")
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return .success(text: path)
        } catch {
            return .failure("write failed: \(error)")
        }
    }
}
#endif
