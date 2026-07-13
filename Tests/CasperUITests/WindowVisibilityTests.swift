import CasperCore
import SwiftUI
import XCTest
@testable import CasperUI

final class WindowVisibilityTests: XCTestCase {
    @MainActor
    func testAppModelDefaultsToVisible() {
        // A headless AppModel (no window attached) must behave as visible so
        // tests and any pre-window state do not suspend work spuriously.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        let model = AppModel(sessionStore: SessionStore(fileURL: url))
        XCTAssertTrue(model.isWindowVisible)
    }

    func testEnvironmentDefaultIsVisible() {
        // The environment value must default true so any view read outside an
        // injected sidebar (previews, detached hosts) animates normally.
        XCTAssertTrue(EnvironmentValues().windowVisible)
    }
}
