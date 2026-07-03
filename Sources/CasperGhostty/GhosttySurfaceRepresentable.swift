import SwiftUI

/// SwiftUI wrapper hosting a `GhosttySurfaceView`. Consumed by CasperUI (Plan 5).
public struct GhosttySurfaceRepresentable: NSViewRepresentable {
    private let runtime: GhosttyRuntime
    private let configuration: GhosttySurfaceConfiguration
    private let surfaceID: UUID
    private let onFocus: (UUID) -> Void

    public init(
        runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration,
        surfaceID: UUID = UUID(), onFocus: @escaping (UUID) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.configuration = configuration
        self.surfaceID = surfaceID
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(
            runtime: runtime, configuration: configuration,
            surfaceID: surfaceID, onFocus: onFocus)
    }

    public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        nsView.onFocus = onFocus
    }
}
