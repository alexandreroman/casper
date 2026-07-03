import AppKit
import Foundation
import XCTest

@testable import CasperGhostty

final class GhosttyFocusCallbackTests: XCTestCase {
    /// The initializer must accept an explicit surface id and focus callback, and the callback
    /// must stay reassignable (the SwiftUI wrapper refreshes it in `updateNSView`). This is
    /// headlessly observable — it needs no real OS focus, only that construction and mutation
    /// do not crash.
    @MainActor
    func testInitWithSurfaceIDAndFocusCallbackDoesNotCrash() {
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration(),
            surfaceID: UUID(), onFocus: { _ in })
        view.onFocus = { _ in }
    }
}
