import AppKit
import XCTest

@testable import CasperUI

/// `DiffHighlighter` hands the diff view one `AttributedString` per source line,
/// indexed by line number, and `DiffTextAssembly` colors a line only when that
/// entry's length matches the line's. So the split is the contract: cut a line
/// ending wrong and every line after it is either miscolored or, once the count
/// check fails, silently rendered neutral with no error and no log.
///
/// `highlightedLines(of:forPath:)` itself cannot run here — it needs
/// HighlightSwift's resource bundle next to `Bundle.main`, which under
/// `swift test` is the toolchain's `usr/bin` — so these drive `splitLines`
/// with the shape the library produces.
final class DiffHighlighterTests: XCTestCase {
    /// Two runs, the second colored, the way HighlightSwift emits a highlighted
    /// file: AppKit-scope attributes, and lines only implied by the `"\n"`
    /// characters inside the runs.
    private func attributed(_ segments: [(String, NSColor?)]) throws -> AttributedString {
        let source = NSMutableAttributedString()
        for (text, color) in segments {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
            if let color { attributes[.foregroundColor] = color }
            source.append(NSAttributedString(string: text, attributes: attributes))
        }
        return try AttributedString(source, including: \.appKit)
    }

    private func text(_ line: AttributedString) -> String {
        String(line.characters)
    }

    func testSplitsOnEveryNewlineAndKeepsBlankLinesInPlace() throws {
        let lines = DiffHighlighter.splitLines(try attributed([("a\n\nb", nil)]))

        XCTAssertEqual(lines.map(text), ["a", "", "b"])
    }

    /// A run boundary is not a line boundary: one line is routinely spread over
    /// several colored runs, and one run routinely spans several lines.
    func testALineSpanningSeveralRunsComesBackWhole() throws {
        let lines = DiffHighlighter.splitLines(
            try attributed([("let ", .systemPink), ("x = 1\nlet ", nil), ("y = 2", .systemTeal)]))

        XCTAssertEqual(lines.map(text), ["let x = 1", "let y = 2"])
    }

    /// A CRLF file's `"\r\n"` is a single `Character` equal to neither `"\n"`
    /// nor a lone `"\r"`, so a character-wise split answers one line for the
    /// whole file — the count check in `highlightedLines` then rejects the
    /// result and the file renders with no syntax colors at all.
    func testCRLFLineEndingsSplitAtTheirLineFeed() throws {
        let source = "let x = 1\r\nlet y = 2\r\n"
        let lines = DiffHighlighter.splitLines(try attributed([(source, nil)]))

        XCTAssertEqual(lines.map(text), ["let x = 1\r", "let y = 2\r", ""])
        // What `highlightedLines` compares against before handing these back.
        XCTAssertEqual(lines.count, 1 + source.unicodeScalars.filter { $0 == "\n" }.count)
    }

    /// The diff view applies its own uniform monospaced face, so a highlight may
    /// carry colors and nothing else — a font riding along would resize a line
    /// and shift the text under a reader mid-scroll.
    func testColorsSurviveAndFontsDoNot() throws {
        let lines = DiffHighlighter.splitLines(try attributed([("keyword", .systemPink)]))
        let highlighted = try XCTUnwrap(lines.first)

        let run = try XCTUnwrap(highlighted.runs.first)
        XCTAssertEqual(run.attributes.appKit.foregroundColor, .systemPink)
        // The font is read through the untyped AppKit key on a bridged
        // `NSAttributedString`: the typed `run.attributes.appKit.font` warns, because
        // the `Sendable` requirement sits on the attribute key and `NSFont` is not
        // `Sendable`. `DiffHighlighter.droppingFonts(_:)` strips it the same way.
        XCTAssertNil(NSAttributedString(highlighted).attribute(.font, at: 0, effectiveRange: nil))
    }
}
