import AppKit
import SwiftUI
import XCTest
@testable import CasperUI

/// Pins the title-bar chips' interaction states: the capsule fill each state
/// picks, and the one thing `TitleChipButtonStyle` must keep from `.plain`.
///
/// The press gesture itself is not driven here — that needs a real click in a
/// real window. What can regress silently is the ordering behind it: a pressed
/// fill that does not read past the hovered one shows nothing at all, because a
/// chip is always hovered while it is held.
@MainActor
final class TitleChipFeedbackTests: XCTestCase {
    func testEachStateReadsStrongerThanTheOneBeforeIt() {
        XCTAssertLessThan(TitleChipFeedback.restingFillOpacity, TitleChipFeedback.hoveredFillOpacity)
        XCTAssertLessThan(TitleChipFeedback.hoveredFillOpacity, TitleChipFeedback.pressedFillOpacity)
    }

    func testPressWinsOverHoverWhichWinsOverRest() {
        XCTAssertEqual(fill(filled: true), TitleChipFeedback.restingFillOpacity)
        XCTAssertEqual(fill(filled: true, hovered: true), TitleChipFeedback.hoveredFillOpacity)
        XCTAssertEqual(fill(filled: true, hovered: true, pressed: true), TitleChipFeedback.pressedFillOpacity)
        // Not reachable with a pointer, but a keyboard or VoiceOver press has no
        // hover to stand on.
        XCTAssertEqual(fill(filled: true, pressed: true), TitleChipFeedback.pressedFillOpacity)
    }

    /// An unfilled chip draws no chrome at rest and grows it on interaction, the
    /// same way a native toolbar button's bezel appears.
    func testUnfilledChipShowsChromeOnlyWhileInteractedWith() {
        XCTAssertNil(fill(filled: false))
        XCTAssertEqual(fill(filled: false, hovered: true), TitleChipFeedback.hoveredFillOpacity)
        XCTAssertEqual(fill(filled: false, pressed: true), TitleChipFeedback.pressedFillOpacity)
    }

    /// The Run chip's primary action is disabled while the workspace's setup hook
    /// runs, and it must still look it after trading `.plain` for the chip style:
    /// `.plain` fades a disabled label, a bare `ButtonStyle` does not.
    func testDisabledLabelRendersAsPlainStyleRendersIt() throws {
        let plain = try darkness(of: Button {} label: { runLabel }.buttonStyle(.plain).disabled(true))
        let chip = try darkness(of: Button {} label: { runLabel }.buttonStyle(TitleChipButtonStyle()).disabled(true))
        let enabled = try darkness(of: Button {} label: { runLabel }.buttonStyle(TitleChipButtonStyle()))

        XCTAssertEqual(chip, plain, accuracy: plain * 0.02)
        // Proves the comparison has teeth: an undimmed label measures far darker.
        XCTAssertGreaterThan(enabled, plain * 1.5)
    }

    // MARK: - Helpers

    private var runLabel: some View {
        Label("Run", systemImage: "play.fill").labelStyle(.titleAndIcon)
    }

    private func fill(filled: Bool, hovered: Bool = false, pressed: Bool = false) -> Double? {
        TitleChipFeedback.fillOpacity(filled: filled, hovered: hovered, pressed: pressed)
    }

    /// Renders `view` on white offscreen and sums how dark its pixels are —
    /// a single number that tracks how strongly the label is drawn. Offscreen, so
    /// no screen-recording grant is involved.
    private func darkness(of view: some View) throws -> Double {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 80, height: 30)
                .background(Color.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var total = 0.0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                total += 1 - Double(color.brightnessComponent)
            }
        }
        return total
    }
}
