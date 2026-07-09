import XCTest
import Foundation
@testable import CasperAgents

final class TerminalLocaleTests: XCTestCase {
    func testEnvironmentAlwaysCarriesUTF8LANG() throws {
        let env = TerminalLocale.environment()
        let lang = try XCTUnwrap(env["LANG"])
        XCTAssertTrue(lang.hasSuffix(".UTF-8"), "expected a UTF-8 LANG, got \(lang)")
    }

    func testResolvedLANGUsesDerivedIdentifierWhenInstalled() {
        let lang = TerminalLocale.resolvedLANG(
            locale: Locale(identifier: "fr_FR"), isInstalled: { _ in true })
        XCTAssertEqual(lang, "fr_FR.UTF-8")
    }

    func testResolvedLANGFallsBackWhenNotInstalled() {
        let lang = TerminalLocale.resolvedLANG(
            locale: Locale(identifier: "fr_FR"), isInstalled: { _ in false })
        XCTAssertEqual(lang, "en_US.UTF-8")
    }

    func testResolvedLANGFallsBackWhenRegionMissing() {
        let lang = TerminalLocale.resolvedLANG(
            locale: Locale(identifier: "eo"), isInstalled: { _ in true })
        XCTAssertEqual(lang, "en_US.UTF-8")
    }
}
