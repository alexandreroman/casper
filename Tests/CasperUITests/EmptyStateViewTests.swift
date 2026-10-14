import AppKit
import SwiftUI
import XCTest
@testable import CasperUI

/// Rendering smoke tests for the no-Spaces screen.
///
/// The view holds no logic — it is two buttons, a hint and three fixed cards — so
/// what is worth pinning is that it *composes and lays out*, and that the widest
/// thing on it stays the onboarding strip. The shortcut hint is `.fixedSize()`, so
/// it can never wrap: grown past the strip's own width it pushes the whole screen
/// open instead, and the width assertion below is what catches that (verified —
/// quadrupling the hint moves the measured width past the bound, the real one stays
/// inside it). Colours, hover states and the click targets themselves are not
/// measurable headlessly (see `headless-swiftui-layout-tests`).
@MainActor
final class EmptyStateViewTests: XCTestCase {
    /// Three cards, the two gaps between them and the screen's padding on both
    /// sides, so a failure below reads as "the hint outgrew the strip" rather than
    /// as an unexplained number.
    private static let onboardingStripWidth: CGFloat =
        3 * EmptyStateView.cardWidth + 2 * EmptyStateView.cardSpacing + 2 * EmptyStateView.screenPadding

    /// The invariant is one-sided: the onboarding strip is meant to be the widest
    /// element, so nothing above it — the `.fixedSize()` hint in particular — may
    /// widen the screen beyond it.
    func testTheStripStaysTheWidestElement() {
        let size = layoutSize(for: EmptyStateView(model: makeModel()))

        XCTAssertLessThanOrEqual(size.width, Self.onboardingStripWidth + 0.5)
        XCTAssertGreaterThan(size.height, 0)
    }
}
