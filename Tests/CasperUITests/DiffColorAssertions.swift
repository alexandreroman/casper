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
