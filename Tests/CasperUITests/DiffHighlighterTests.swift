import AppKit
import HighlightSwift
import SwiftUI
import XCTest

@testable import CasperUI

/// `DiffHighlighter` hands the diff view one `AttributedString` per source line,
/// indexed by line number, and `DiffTextAssembly` colors a line only when that
/// entry's length matches the line's. So the split and its alignment with the
/// source are the contract: cut a line ending wrong, or lose a line the library
/// trimmed, and every line after it is either miscolored or, once the alignment
/// fails, silently rendered neutral with no error and no log.
///
/// `highlightedLines(of:forPath:)` itself cannot run here — it needs
/// HighlightSwift's resource bundle next to `Bundle.main`, which under
/// `swift test` is the toolchain's `usr/bin` — so these drive `splitLines` and
/// `lines(fromLibraryOutput:alignedTo:)` with the shape the library produces.
///
/// Main-actor bound because `libraryOutput(for:)` imports HTML, which AppKit
/// only does on the main thread.
@MainActor
final class DiffHighlighterTests: XCTestCase {
    /// Two runs, the second colored, the way HighlightSwift emits a highlighted
    /// file: AppKit-scope attributes, and lines only implied by the `"\n"`
    /// characters inside the runs.
    private func attributed(_ segments: [(String, NSColor?)]) throws -> AttributedString {
        let source = NSMutableAttributedString()
        for (text, color) in segments {
            var attributes: [NSAttributedString.Key: Any] = [:]
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

    /// What HighlightSwift hands back for `source`, built the way its
    /// `Highlight.request` builds it, minus the JavaScript pass whose spans only
    /// add colors: the text trimmed of edge whitespace and newlines, wrapped in
    /// `<pre><code>`, imported as HTML — which turns a CRLF into a bare LF — and
    /// stripped of the newline the import appends.
    private func libraryOutput(for source: String) throws -> AttributedString {
        let html = "<pre><code>" + source.trimmingCharacters(in: .whitespacesAndNewlines) + "</code></pre>"
        let imported = try NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil)
        let withoutFinalNewline = imported.attributedSubstring(
            from: NSRange(location: 0, length: imported.length - 1))
        return try AttributedString(withoutFinalNewline, including: \.appKit)
    }

    /// A CRLF file is highlighted with bare LFs, and the library's trim drops its
    /// final line break: the trailing empty line comes back as padding, and every
    /// line keeps its source index.
    func testCRLFLinesLineUpWithTheirSource() throws {
        let source = DiffHighlighter.normalizingLineEndings("let a = 1\r\nlet b = 2\r\n")
        XCTAssertEqual(source, "let a = 1\nlet b = 2\n")

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(for: source), alignedTo: source))

        XCTAssertEqual(lines.map(text), ["let a = 1", "let b = 2", ""])
    }

    /// The library trims blank lines off both ends of the file; they come back as
    /// empty lines, so the code between them stays at its source line numbers.
    func testBlankLinesTrimmedOffBothEndsComeBackEmpty() throws {
        let source = "\n\nlet a = 1\nlet b = 2\n\n"

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(for: source), alignedTo: source))

        XCTAssertEqual(lines.map(text), ["", "", "let a = 1", "let b = 2", "", ""])
    }

    /// More lines than the source has cannot be lined up with it, so the file
    /// falls back to neutral rather than miscoloring.
    func testOutputLongerThanTheSourceIsRejected() throws {
        XCTAssertNil(DiffHighlighter.lines(fromLibraryOutput: try attributed([("a\nb\nc", nil)]), alignedTo: "a\nb"))
    }

    /// A run's color survives the cut, read from the AppKit scope the library
    /// fills.
    func testColorsSurviveTheSplit() throws {
        let lines = DiffHighlighter.splitLines(try attributed([("keyword", .systemPink)]))
        let highlighted = try XCTUnwrap(lines.first)

        let run = try XCTUnwrap(highlighted.runs.first)
        XCTAssertEqual(run.attributes.appKit.foregroundColor, .systemPink)
    }

    /// The palette follows the appearance: GitHub's light theme for `.light`, its
    /// dark one for `.dark`.
    func testColorsFollowTheColorScheme() {
        XCTAssertEqual(DiffHighlighter.colors(for: .light), .light(.github))
        XCTAssertEqual(DiffHighlighter.colors(for: .dark), .dark(.github))
    }
}
