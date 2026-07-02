#if DEBUG
import AppKit
import CasperCore
import CoreGraphics

/// Full geometry snapshot of one surface: libghostty's pixel readback plus the
/// hosting view's AppKit metrics. Carries the numbers `dumpState` reports without
/// coupling this module's handle to `DebugState`.
public struct DebugSurfaceGeometry: Sendable {
    public let columns: Int
    public let rows: Int
    public let widthPixels: Int
    public let heightPixels: Int
    public let cellWidthPixels: Int
    public let cellHeightPixels: Int
    public let boundsWidth: Double
    public let boundsHeight: Double
    public let backingWidth: Double
    public let backingHeight: Double
    public let contentScaleX: Double
    public let contentScaleY: Double
    public let backingScaleFactor: Double

    public init(
        columns: Int, rows: Int,
        widthPixels: Int, heightPixels: Int,
        cellWidthPixels: Int, cellHeightPixels: Int,
        boundsWidth: Double, boundsHeight: Double,
        backingWidth: Double, backingHeight: Double,
        contentScaleX: Double, contentScaleY: Double,
        backingScaleFactor: Double
    ) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.boundsWidth = boundsWidth
        self.boundsHeight = boundsHeight
        self.backingWidth = backingWidth
        self.backingHeight = backingHeight
        self.contentScaleX = contentScaleX
        self.contentScaleY = contentScaleY
        self.backingScaleFactor = backingScaleFactor
    }
}

/// A snapshot description of one live surface, decoupling `DebugServer` from the
/// concrete AppKit view. The provider builds these on the main thread.
@MainActor
public struct DebugSurfaceHandle {
    public let id: String
    public let title: String
    public let workingDirectory: String?
    public let focused: Bool
    public let readText: (_ scrollback: Bool) -> String?
    public let sendText: (_ text: String, _ submit: Bool) -> Void
    public let sendKeys: (_ text: String) -> Void
    public let sendCtrl: (_ text: String) -> Void
    public let geometry: () -> DebugSurfaceGeometry
    public let focus: () -> Void
    public let window: NSWindow?

    public init(
        id: String, title: String, workingDirectory: String?, focused: Bool,
        readText: @escaping (_ scrollback: Bool) -> String?,
        sendText: @escaping (_ text: String, _ submit: Bool) -> Void,
        sendKeys: @escaping (_ text: String) -> Void,
        sendCtrl: @escaping (_ text: String) -> Void,
        geometry: @escaping () -> DebugSurfaceGeometry,
        focus: @escaping () -> Void,
        window: NSWindow?
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.focused = focused
        self.readText = readText
        self.sendText = sendText
        self.sendKeys = sendKeys
        self.sendCtrl = sendCtrl
        self.geometry = geometry
        self.focus = focus
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
                let g = handle.geometry()
                return DebugState.Surface(
                    id: handle.id, title: handle.title, workingDirectory: handle.workingDirectory,
                    columns: g.columns, rows: g.rows, focused: handle.focused,
                    widthPixels: g.widthPixels, heightPixels: g.heightPixels,
                    cellWidthPixels: g.cellWidthPixels, cellHeightPixels: g.cellHeightPixels,
                    boundsWidth: g.boundsWidth, boundsHeight: g.boundsHeight,
                    backingWidth: g.backingWidth, backingHeight: g.backingHeight,
                    contentScaleX: g.contentScaleX, contentScaleY: g.contentScaleY,
                    backingScaleFactor: g.backingScaleFactor)
            }
            return .success(state: DebugState(surfaces: entries))

        case .readText:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = handle.readText(command.scrollback ?? false) else {
                return .failure("read-text unavailable")
            }
            return .success(text: text)

        case .sendText:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = command.text else { return .failure("missing text") }
            handle.sendText(text, command.enter == true)
            return .success()

        case .sendKeys:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = command.text else { return .failure("missing text") }
            handle.sendKeys(text)
            return .success()

        case .sendCtrl:
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let text = command.text else { return .failure("missing text") }
            handle.sendCtrl(text)
            return .success()

        case .screenshot:
            guard let path = command.path else { return .failure("missing path") }
            guard let handle = target(in: surfaces, matching: command.target) else {
                return targetFailure(command.target)
            }
            guard let window = handle.window else { return .failure("no window") }
            return screenshot(window: window, to: path)

        case .focus:
            guard let id = command.target else { return .failure("missing target id") }
            guard let handle = surfaces.first(where: { $0.id == id }) else {
                return .failure("no surface with id \(id)")
            }
            handle.focus()
            return .success()
        }
    }

    /// The surface a verb acts on: the id-matched surface when `target` is set,
    /// otherwise the focused surface (falling back to the first). A set-but-
    /// unmatched target returns nil — never a silent fallback.
    private func target(
        in surfaces: [DebugSurfaceHandle], matching target: String?
    ) -> DebugSurfaceHandle? {
        if let target { return surfaces.first(where: { $0.id == target }) }
        return focusedOrFirst(surfaces)
    }

    /// The failure for an unresolved target: id-specific when a target was
    /// given, generic when none was.
    private func targetFailure(_ target: String?) -> DebugResponse {
        if let target { return .failure("no surface with id \(target)") }
        return .failure("no surface")
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
