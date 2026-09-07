import Foundation
import XCTest
@testable import CasperUI

/// Tests for the width the title-bar row *declares* while the window is being
/// dragged, as opposed to the width it settles on.
///
/// The row lives in a single `ToolbarItem` and AppKit never squeezes such an item:
/// too wide, and the whole title bar goes into the overflow chevron (see the
/// `toolbar-overflows-before-squeezing` note). The width the row declares is derived
/// from the detail area's geometry, captured into `@State`, so it is inherently one
/// layout pass behind the window — and AppKit runs its fit check against that stale
/// value. Measured on the running app with the `CASPER_RESIZESTEP` probe, a shrink of
/// 40 pt per pass raised the chevron on 18 of 19 steps, while no growth step ever
/// did: the lag leaves the row too WIDE on a shrink and merely too narrow on a grow.
///
/// The invariant that closes the gap is not "the row fits the bar it was measured
/// against" — it already did — but **the declared width must fall at least as fast as
/// the bar does**, so that the stale value AppKit judges is already narrow enough for
/// the bar of the next pass. That is pure arithmetic over two measurements, which is
/// why it is testable without a window: the two decisions live in
/// `WorkspaceDetailView.shrink(previousWidth:newWidth:)` and
/// `WorkspaceDetailView.rowWidth(detailFrame:undershoot:)`, and this suite composes
/// them exactly as the view does.
///
/// Nothing here hard-codes AppKit's own insets (the item viewer starts a few points
/// inside the detail area, and that offset is neither published nor stable). The
/// assertions are relative — this pass against the next pass — so they hold whatever
/// those insets turn out to be.
@MainActor
final class WorkspaceTitleBarWidthTests: XCTestCase {
    /// Per-pass shrinks to sweep, in points. 8 pt is a slow drag (measured: 1 chevron
    /// in 14 steps), 16 pt is where the flicker becomes the common case (6 in 8),
    /// 40 pt is the step the flicker was characterised at (18 in 19), and 120 pt
    /// stands in for a flick of the pointer.
    private static let shrinkSteps: [CGFloat] = [8, 16, 40, 120]

    /// Detail-area widths to sweep. All are far enough above the mount threshold that
    /// the clamp protecting it never applies — that band is
    /// `testTheMountThresholdHoldsUnderAFastShrink`'s subject, and the two
    /// requirements genuinely conflict there.
    private static let detailWidths: [CGFloat] = [400, 700, 1000, 1600]

    /// The two window-chrome cases. `0` is the detail area at the window's leading
    /// edge — the sidebar is collapsed, so the traffic lights and the sidebar toggle
    /// share this row — and `220` is a detail area inset by the sidebar column, where
    /// they cost it nothing.
    private static let detailOrigins: [CGFloat] = [0, 220]

    /// The core invariant: for a constant-velocity shrink, the width declared for the
    /// frame just measured is exactly the width the NEXT frame would declare with no
    /// slack at all.
    ///
    /// AppKit judges the declared value against the bar one pass later, so this is
    /// exactly "the stale row still fits". Swept across shrink speeds, starting widths
    /// and both chrome cases, since the failure is speed-dependent: the old formula
    /// survived anything up to `safetyMargin` per pass and overflowed above it.
    ///
    /// Equality, not an upper bound, because the row must fall exactly as fast as the
    /// bar — no slower, which overflows the item into the chevron, and no faster,
    /// which folds the chips for nothing and leaves them folded for the whole drag
    /// plus the settle delay. Outside the mount-threshold band (the fixture guard
    /// below keeps the sweep clear of it) the clamp never intervenes, so there is no
    /// slack left for either direction to hide in.
    ///
    /// The equality holds only up to `maximumResizeUndershoot`. Above it the
    /// anticipation deliberately stops short, so the 120 pt step asserts the capped
    /// number instead: a jump that large is a coalesced pass, not a velocity, and
    /// answering it in full would collapse the row where one frame of chevron —
    /// which `healToolbarOverflow` recovers — costs far less.
    func testTheDeclaredWidthMatchesTheBarTheNextPassOffers() {
        for minX in Self.detailOrigins {
            for step in Self.shrinkSteps {
                for width in Self.detailWidths {
                    let context = "minX=\(minX) step=\(step) width=\(width)"
                    let declared = declaredWidth(previousWidth: width + step, newWidth: width, minX: minX)
                    let nextSettled = WorkspaceDetailView.rowWidth(
                        detailFrame: frame(width: width - step, minX: minX), undershoot: 0)

                    // Guards the fixture, not the code: a sweep that wandered into the
                    // mount-threshold band would be asserting the wrong requirement.
                    XCTAssertGreaterThan(
                        nextSettled, WorkspaceDetailView.minimumRowWidth,
                        "fixture too narrow to test this invariant: \(context)")

                    guard step > WorkspaceDetailView.maximumResizeUndershoot else {
                        XCTAssertEqual(
                            declared, nextSettled, accuracy: 0.001,
                            "the stale row misses the bar by \(declared - nextSettled) pt: \(context)")
                        continue
                    }
                    XCTAssertEqual(
                        declared,
                        settledWidth(width, minX: minX) - WorkspaceDetailView.maximumResizeUndershoot,
                        accuracy: 0.001,
                        "a capped pass declared something other than a cap's worth of undershoot: \(context)")
                }
            }
        }
    }

    /// A widening pass declares today's width, unchanged. The lag is harmless in that
    /// direction — it leaves the row narrower than the bar, which wastes a few
    /// invisible points at the trailing edge — so a grow must buy no undershoot at
    /// all, or the row would visibly lag behind a window being opened up.
    func testAWideningPassDeclaresTheSettledWidth() {
        for minX in Self.detailOrigins {
            for step in Self.shrinkSteps {
                for width in Self.detailWidths {
                    let context = "minX=\(minX) step=\(step) width=\(width)"
                    XCTAssertEqual(
                        WorkspaceDetailView.shrink(previousWidth: width - step, newWidth: width), 0,
                        "a grow bought undershoot: \(context)")
                    XCTAssertEqual(
                        declaredWidth(previousWidth: width - step, newWidth: width, minX: minX),
                        settledWidth(width, minX: minX), accuracy: 0.001, context)
                }
            }
        }
    }

    /// A settled row is exact: with no shrink to compensate for, the declared width is
    /// the detail area's width less the window's chrome and the standing safety
    /// margin, and nothing else. This is what the debounce in `WorkspaceDetailView`
    /// restores once a drag stops — without it the row would stay permanently
    /// narrower than the bar by however fast the last drag happened to be moving.
    ///
    /// A pass that measures no change, and the very first pass of all (no previous
    /// frame to compare against), are both this case.
    func testASettledRowDeclaresItsExactWidth() {
        for minX in Self.detailOrigins {
            for width in Self.detailWidths {
                let context = "minX=\(minX) width=\(width)"
                XCTAssertEqual(
                    WorkspaceDetailView.shrink(previousWidth: width, newWidth: width), 0,
                    "a stationary window bought undershoot: \(context)")
                XCTAssertEqual(
                    WorkspaceDetailView.shrink(previousWidth: nil, newWidth: width), 0,
                    "the first measurement bought undershoot: \(context)")
                XCTAssertEqual(
                    declaredWidth(previousWidth: width, newWidth: width, minX: minX),
                    settledWidth(width, minX: minX), accuracy: 0.001, context)
            }
        }
    }

    /// The undershoot must never carry the row across the mount threshold. Below
    /// `minimumRowWidth` the item is dropped from the toolbar entirely, and an item
    /// that unmounts and remounts once per frame of a drag is a worse flicker than the
    /// overflow this undershoot exists to prevent.
    ///
    /// Swept one point at a time across the whole band where the settled row sits at
    /// or just above the threshold. The cap alone does not save this: at the bottom of
    /// the band the settled row is `minimumRowWidth` wide and a full cap's worth of
    /// undershoot would take it to nothing, so the clamp still has to intervene.
    func testTheMountThresholdHoldsUnderAFastShrink() {
        for minX in Self.detailOrigins {
            let chrome = minX < 1 ? WorkspaceDetailView.windowChromeReserve : 0
            // The detail width whose settled row is exactly `minimumRowWidth` wide.
            let floor = WorkspaceDetailView.minimumRowWidth + WorkspaceDetailView.safetyMargin + chrome
            // Guards the fixture, not the code, and once rather than per width: the
            // band starts exactly ON the threshold, and `settledWidth` subtracts the
            // same two constants `floor` is built from, so every wider width in the
            // sweep clears the threshold precisely because this one meets it.
            XCTAssertEqual(
                settledWidth(floor, minX: minX), WorkspaceDetailView.minimumRowWidth,
                accuracy: 0.001,
                "the sweep does not start at the mount threshold: minX=\(minX)")

            for width in stride(from: floor, through: floor + 200, by: 1) {
                for step in Self.shrinkSteps {
                    let context = "minX=\(minX) step=\(step) width=\(width)"
                    XCTAssertGreaterThanOrEqual(
                        declaredWidth(previousWidth: width + step, newWidth: width, minX: minX),
                        WorkspaceDetailView.minimumRowWidth,
                        "the undershoot unmounted the row: \(context)")
                }
            }

            // The clamp must not over-reach either: a detail area that genuinely
            // cannot hold the row still reports below the threshold, so the row is
            // dropped rather than mounted at a width AppKit would answer with a
            // chevron.
            let tooNarrow = floor - 1
            XCTAssertLessThan(
                declaredWidth(previousWidth: tooNarrow + 120, newWidth: tooNarrow, minX: minX),
                WorkspaceDetailView.minimumRowWidth,
                "a row too narrow to mount was clamped into the toolbar: minX=\(minX)")
        }
    }

    /// The declared width must be MONOTONE across one drag, and a real drag's deltas
    /// fluctuate: they are not per-frame increments but whatever distance the pointer
    /// covered since the last layout pass, which SwiftUI coalesces freely.
    ///
    /// This is the load-bearing invariant, because the row's `ViewThatFits` ladder is
    /// chosen from the declared width: a width that falls and rises again walks the
    /// ladder back UP a rung, bringing the diff badge, the Space name and the chip
    /// labels back mid-drag. Non-monotone degradation is the exact failure the single
    /// ordered ladder exists to prevent, so a drag that only ever narrows the window
    /// must only ever narrow the row.
    func testAJitteringShrinkNeverWidensTheDeclaredRow() {
        for minX in Self.detailOrigins {
            let declared = declaredWidths(alongDrag: Self.jitteringDrag, minX: minX, isLiveResize: true)
            for (index, width) in declared.enumerated().dropFirst() {
                XCTAssertLessThanOrEqual(
                    width, declared[index - 1],
                    "pass \(index) widened the row from \(declared[index - 1]) to \(width) "
                        + "(minX=\(minX), all=\(declared))")
            }
        }
    }

    /// No pass may withhold more than `maximumResizeUndershoot`, so a row whose settled
    /// width is comfortably above the mount threshold never falls onto it.
    ///
    /// The fixture is the collapse the trace caught verbatim: a 990 pt window whose
    /// detail area measures 762 pt, then ONE coalesced pass 562 pt narrower. Answering
    /// that 562 in full took the row to `minimumRowWidth` — the bare `⋯` chip — where
    /// a settled 184 pt row still has room for more than that.
    func testTheUndershootNeverExceedsItsCap() {
        let cap = WorkspaceDetailView.maximumResizeUndershoot
        for shrink in Self.shrinkSteps + [562, 5000] {
            for current in [0, cap / 2, cap] {
                for isLiveResize in [true, false] {
                    let context = "shrink=\(shrink) current=\(current) live=\(isLiveResize)"
                    let next = WorkspaceDetailView.nextUndershoot(
                        current: current, shrink: shrink, isLiveResize: isLiveResize)
                    XCTAssertLessThanOrEqual(next, cap, "the undershoot broke its cap: \(context)")
                }
            }
        }

        let traced = declaredWidths(alongDrag: [762, 208], minX: 220, isLiveResize: true)
        XCTAssertEqual(traced[1], settledWidth(208, minX: 220) - cap, accuracy: 0.001)
        XCTAssertGreaterThan(
            traced[1], WorkspaceDetailView.minimumRowWidth,
            "the row collapsed onto the ladder's floor: \(traced)")
    }

    /// Outside a live resize the capped shrink applies as-is, with no ratchet.
    ///
    /// There is no drag to stay monotone across — a zoom or a programmatic `setFrame`
    /// is one isolated jump — so it must be anticipated once and then given back on
    /// the next pass, rather than held for as long as the window keeps moving.
    func testAJumpOutsideALiveResizeIsAnticipatedOnce() {
        let cap = WorkspaceDetailView.maximumResizeUndershoot
        XCTAssertEqual(
            WorkspaceDetailView.nextUndershoot(current: 0, shrink: 12, isLiveResize: false), 12,
            "an ordinary jump was not anticipated in full")
        XCTAssertEqual(
            WorkspaceDetailView.nextUndershoot(current: 0, shrink: 562, isLiveResize: false), cap,
            "a coalesced jump was not capped")
        XCTAssertEqual(
            WorkspaceDetailView.nextUndershoot(current: cap, shrink: 8, isLiveResize: false), 8,
            "the undershoot ratcheted outside a live resize")
        XCTAssertEqual(
            WorkspaceDetailView.nextUndershoot(current: cap, shrink: 0, isLiveResize: false), 0,
            "the undershoot outlived the jump that bought it")

        // The same two passes inside a drag: the ratchet holds the cap through the
        // small one, which is what keeps the width monotone.
        XCTAssertEqual(
            WorkspaceDetailView.nextUndershoot(current: cap, shrink: 8, isLiveResize: true), cap,
            "the ratchet let the undershoot shrink mid-drag")
    }

    /// Detail-area widths of one hand-driven drag, derived from per-pass deltas that
    /// fluctuate the way a real one's do (12, 562, 40, 8, 300, 20) — including one far
    /// above the cap and, right after it, one far below.
    private static let jitteringDrag: [CGFloat] = [1200, 1188, 626, 586, 578, 278, 258]

    /// Replays a drag pass by pass, threading the undershoot through the two pure
    /// decisions exactly as `recordDetailFrame` does, and returns the width the row
    /// declares at each pass.
    private func declaredWidths(
        alongDrag widths: [CGFloat], minX: CGFloat, isLiveResize: Bool
    ) -> [CGFloat] {
        var undershoot: CGFloat = 0
        var previousWidth: CGFloat?
        var declared: [CGFloat] = []
        for width in widths {
            let shrink = WorkspaceDetailView.shrink(previousWidth: previousWidth, newWidth: width)
            undershoot = WorkspaceDetailView.nextUndershoot(
                current: undershoot, shrink: shrink, isLiveResize: isLiveResize)
            previousWidth = width
            declared.append(
                WorkspaceDetailView.rowWidth(
                    detailFrame: frame(width: width, minX: minX), undershoot: undershoot))
        }
        return declared
    }

    // MARK: - Helpers

    /// A detail-area frame, as `.onGeometryChange` reports it: window coordinates, so
    /// `minX` is what says whether the window's own chrome shares this row.
    private func frame(width: CGFloat, minX: CGFloat) -> CGRect {
        CGRect(x: minX, y: 0, width: width, height: 600)
    }

    /// The width the row declares on a pass that measured `newWidth` immediately after
    /// `previousWidth` — the two pure functions composed exactly as the view composes
    /// them.
    private func declaredWidth(previousWidth: CGFloat, newWidth: CGFloat, minX: CGFloat) -> CGFloat {
        declaredWidths(alongDrag: [previousWidth, newWidth], minX: minX, isLiveResize: false)[1]
    }

    /// The width a settled row is expected to declare, spelled out from the shipped
    /// constants rather than read back out of the code under test.
    private func settledWidth(_ width: CGFloat, minX: CGFloat) -> CGFloat {
        let chrome = minX < 1 ? WorkspaceDetailView.windowChromeReserve : 0
        return max(0, width - chrome - WorkspaceDetailView.safetyMargin)
    }
}
