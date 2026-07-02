import SwiftUI

/// SwiftUI wrapper hosting a `GhosttySurfaceView`. Consumed by CasperUI (Plan 5).
public struct GhosttySurfaceRepresentable: NSViewRepresentable {
    private let runtime: GhosttyRuntime
    private let configuration: GhosttySurfaceConfiguration

    public init(runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
    }

    public func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(runtime: runtime, configuration: configuration)
    }

    public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}
