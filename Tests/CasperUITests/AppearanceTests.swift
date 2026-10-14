import AppKit
import XCTest
@testable import CasperUI

final class AppearanceTests: XCTestCase {
    func testIsDarkMatchesTheAppearanceFamily() {
        XCTAssertTrue(NSAppearance(named: .darkAqua)!.isDark)
        XCTAssertTrue(NSAppearance(named: .vibrantDark)!.isDark)
        XCTAssertFalse(NSAppearance(named: .aqua)!.isDark)
        XCTAssertFalse(NSAppearance(named: .vibrantLight)!.isDark)
    }

    /// Headless tests have no runtime; forwarding must be a silent no-op.
    @MainActor
    func testApplyColorSchemeWithoutARuntimeIsANoOp() {
        let model = makeModel()
        model.applyColorScheme(dark: true)
        XCTAssertNil(model.runtime)
    }
}
