import AppKit
import XCTest

// Shared by the diff suites that read colors back out of a rendered bitmap:
// `DiffChromeTests` and `DiffTextSurfaceTests`.

// MARK: - Color assertions

/// The largest per-channel difference between two colors, both taken into device
/// RGB. A color read out of a bitmap is a plain device RGB value, so this is how it
/// gets compared to a catalog color at all.
func channelDistance(_ one: NSColor, _ other: NSColor) -> CGFloat {
    guard let one = one.usingColorSpace(.deviceRGB), let other = other.usingColorSpace(.deviceRGB) else {
        return .greatestFiniteMagnitude
    }
    return max(abs(one.redComponent - other.redComponent),
               abs(one.greenComponent - other.greenComponent),
               abs(one.blueComponent - other.blueComponent))
}

/// `ink` painted over `background` at the ink's own alpha — what a translucent
/// color actually deposits in the bitmap. Opaque ink comes back unchanged, so this
/// is safe to apply to every color the gutter draws.
func composite(_ ink: NSColor, over background: NSColor) -> NSColor {
    guard let ink = ink.usingColorSpace(.deviceRGB), let background = background.usingColorSpace(.deviceRGB)
    else { return ink }
    let alpha = ink.alphaComponent
    func blend(_ channel: KeyPath<NSColor, CGFloat>) -> CGFloat {
        ink[keyPath: channel] * alpha + background[keyPath: channel] * (1 - alpha)
    }
    return NSColor(deviceRed: blend(\.redComponent), green: blend(\.greenComponent),
                   blue: blend(\.blueComponent), alpha: 1)
}

/// Equal drawn colors, within a tolerance that absorbs the round trip through the
/// bitmap. Not `==`: `NSColor` equality compares catalog identity, and nothing read
/// back out of a bitmap has any.
func assertSameColor(
    _ actual: NSColor, _ expected: NSColor, _ context: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    let distance = channelDistance(actual, expected)
    XCTAssertLessThan(
        distance, 0.02, "\(context()): drew \(actual), expected \(expected)", file: file, line: line)
}

// MARK: - Bitmap canvas

/// One view's pixels, plus the rect of that view they cover.
///
/// `cacheDisplay(in:to:)` renders a view through its real `draw(_:)` path into an
/// offscreen bitmap. **No window, no screen and no screen-recording permission are
/// involved**, which is what makes pixel assertions possible in these suites at all —
/// a reader who assumes otherwise will leave visual equivalence unasserted.
///
/// Two things to respect when sampling one:
///
/// - **The bitmap comes back at the display's backing scale, so its pixel coordinates
///   are not points** (2× on a Retina Mac). Every accessor here takes points and
///   converts with a scale measured off the rep, so the same assertions hold at 1×.
/// - **A canvas may cover only part of its view**, when only a strip was repainted.
///   Sampling outside it fails rather than silently reading the nearest edge pixel,
///   which would pass for the wrong reason.
///
/// `@MainActor` because every AppKit call it makes is.
@MainActor
struct BitmapCanvas {
    let bitmap: NSBitmapImageRep
    /// The view rect the bitmap covers, in that view's own points.
    let rect: NSRect

    /// Repaints `view` from `top` down to its bottom edge into an offscreen bitmap.
    init(of view: NSView, repaintingFrom top: CGFloat = 0) throws {
        let rect = NSRect(x: view.bounds.minX, y: top,
                          width: view.bounds.width, height: view.bounds.maxY - top).integral
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        self.bitmap = bitmap
        self.rect = rect
    }

    /// What the view painted at a point in its own coordinates.
    func color(x: CGFloat, y: CGFloat) -> NSColor {
        let pixelX = Int((x - rect.minX) * scale)
        let pixelY = Int((y - rect.minY) * scale)
        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            XCTFail("(\(x), \(y)) falls outside the repainted \(rect)")
            return .clear
        }
        return bitmap.colorAt(x: pixelX, y: pixelY) ?? .clear
    }

    /// The canvas's pixel rows, top-down — for a caller that scans the whole height
    /// instead of sampling points it can predict.
    var pixelRows: Range<Int> { 0..<bitmap.pixelsHigh }

    /// What the canvas holds at one of those rows, sampled at its horizontal middle.
    /// Taken by pixel row rather than by point so a scan cannot round its way onto a
    /// neighbouring row.
    func color(atPixelRow row: Int) -> NSColor {
        bitmap.colorAt(x: bitmap.pixelsWide / 2, y: row) ?? .clear
    }

    /// A pixel row back in the view's own points.
    func points(pixelRow row: Int) -> CGFloat { rect.minY + CGFloat(row) / scale }

    private var scale: CGFloat { CGFloat(bitmap.pixelsWide) / rect.width }
}
