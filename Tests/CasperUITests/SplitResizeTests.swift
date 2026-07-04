import XCTest
import CasperCore
@testable import CasperUI

/// Exercises the pure `SplitContainerView.resizedFractions` resize math, which is
/// where all the divider-drag geometry lives.
final class SplitResizeTests: XCTestCase {
    private let accuracy = 1e-9

    /// Sum of the resulting fractions must stay ≈ 1 (a moved boundary only shifts
    /// mass between two adjacent panes).
    private func assertSumIsOne(_ fractions: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: accuracy, file: file, line: line)
    }

    func testMiddleDividerMovesOnlyAdjacentFractions() {
        let axisLength: CGFloat = 300  // three equal panes, boundaries at 100 and 200
        let start = [1.0 / 3, 1.0 / 3, 1.0 / 3]

        // Drag divider 1 (between panes 1 and 2) from 200 to 240.
        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 1, boundaryTarget: 240, axisLength: axisLength, minLength: 60)

        XCTAssertEqual(result[0], start[0], accuracy: accuracy)   // pane 0 untouched
        XCTAssertEqual(result[1], (240 - 100) / 300, accuracy: accuracy)
        XCTAssertEqual(result[2], (300 - 240) / 300, accuracy: accuracy)
        assertSumIsOne(result)
    }

    func testFirstDividerBinarySplit() {
        let axisLength: CGFloat = 200
        let start = [0.5, 0.5]

        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 0, boundaryTarget: 130, axisLength: axisLength, minLength: 60)

        XCTAssertEqual(result[0], 130.0 / 200, accuracy: accuracy)
        XCTAssertEqual(result[1], 70.0 / 200, accuracy: accuracy)
        assertSumIsOne(result)
    }

    func testLastDividerLeavesEarlierPanesUntouched() {
        let axisLength: CGFloat = 400  // four equal panes, last divider is index 2 at 300
        let start = [0.25, 0.25, 0.25, 0.25]

        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 2, boundaryTarget: 260, axisLength: axisLength, minLength: 60)

        XCTAssertEqual(result[0], start[0], accuracy: accuracy)
        XCTAssertEqual(result[1], start[1], accuracy: accuracy)
        XCTAssertEqual(result[2], (260 - 200) / 400, accuracy: accuracy)
        XCTAssertEqual(result[3], (400 - 260) / 400, accuracy: accuracy)
        assertSumIsOne(result)
    }

    func testClampFarLeftPinsPaneAtMinLength() {
        let axisLength: CGFloat = 200
        let minLength: CGFloat = 60
        let start = [0.5, 0.5]

        // Drag toward 0; the left pane must not shrink below minLength.
        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 0, boundaryTarget: -50, axisLength: axisLength, minLength: minLength)

        XCTAssertEqual(result[0] * axisLength, minLength, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(result[1] * axisLength, Double(minLength) - accuracy)
        assertSumIsOne(result)
    }

    func testClampFarRightPinsNeighbourAtMinLength() {
        let axisLength: CGFloat = 200
        let minLength: CGFloat = 60
        let start = [0.5, 0.5]

        // Drag past the far edge; the right pane must not shrink below minLength.
        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 0, boundaryTarget: 500, axisLength: axisLength, minLength: minLength)

        XCTAssertEqual(result[1] * axisLength, minLength, accuracy: accuracy)
        XCTAssertGreaterThanOrEqual(result[0] * axisLength, Double(minLength) - accuracy)
        assertSumIsOne(result)
    }

    func testGuardReturnsUnchangedWhenPairTooSmall() {
        // The two panes together span only 100pt, below 2 * minLength (120), so
        // there is no room to move the divider either way.
        let axisLength: CGFloat = 500
        let start = [0.1, 0.1, 0.8]  // panes 0 and 1 total 100pt

        let result = SplitContainerView.resizedFractions(
            start, dividerIndex: 0, boundaryTarget: 30, axisLength: axisLength, minLength: 60)

        XCTAssertEqual(result, start)
    }

    func testInvalidIndexReturnsUnchanged() {
        let start = [0.5, 0.5]

        XCTAssertEqual(
            SplitContainerView.resizedFractions(
                start, dividerIndex: -1, boundaryTarget: 50, axisLength: 200, minLength: 60),
            start)
        // dividerIndex + 1 must be a valid pane; index 1 has no pane 2 here.
        XCTAssertEqual(
            SplitContainerView.resizedFractions(
                start, dividerIndex: 1, boundaryTarget: 50, axisLength: 200, minLength: 60),
            start)
    }
}
