import AppKit
import HighlightSwift
import SwiftUI
import XCTest

@testable import CasperUI

/// `DiffHighlighter` hands the diff view one `AttributedString` per source line,
/// indexed by line number, and `DiffTextAssembly` colors a line only when that
/// entry's length matches the line's. So the split and its alignment with the
/// source are the contract: cut a line ending wrong, or accept output whose text
/// is not exactly the source, and every line after it is either miscolored or,
/// once the alignment fails, silently rendered neutral with no error and no log.
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
    /// add colors: the source stands in for highlight.js's markup (none of these
    /// sources holds a character HTML would need escaped). See
    /// `libraryOutput(forHighlightedHTML:source:)`.
    private func libraryOutput(for source: String) throws -> AttributedString {
        try libraryOutput(forHighlightedHTML: source, source: source)
    }

    /// What HighlightSwift hands back for `source`, given `highlightedHTML`, the
    /// markup highlight.js made of it: that markup, untrimmed and with every CR
    /// escaped as `&#13;`, wrapped in `<pre><code class="hljs">` and imported as
    /// HTML. When the imported text starts with the source, exactly the source's
    /// length is taken — dropping the newline the import appends — and converted
    /// with the AppKit scope; otherwise the library falls back to the uncolored
    /// source. The palette's `<style>` and the font removal are left out: they
    /// change no character.
    private func libraryOutput(forHighlightedHTML highlightedHTML: String, source: String) throws -> AttributedString {
        let code = highlightedHTML.replacingOccurrences(of: "\r", with: "&#13;")
        let html = "<pre><code class=\"hljs\">" + code + "</code></pre>"
        let imported = try NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil)
        guard imported.string.utf8.starts(with: source.utf8) else {
            return AttributedString(source)
        }
        let sourceRange = NSRange(location: 0, length: source.utf16.count)
        return try AttributedString(imported.attributedSubstring(from: sourceRange), including: \.appKit)
    }

    /// Markup coloring `text` red with an inline style, standing in for a
    /// highlight.js span whose color would come from the palette's CSS.
    private func red(_ text: String) -> String {
        #"<span style="color: #ff0000">"# + text + "</span>"
    }

    /// The text of `line`'s runs painted red, to tell a colored line from the
    /// uncolored fallback and to check the color landed on the right characters.
    private func redText(_ line: AttributedString) -> String {
        var text = ""
        for run in line.runs where isRed(run.attributes.appKit.foregroundColor) {
            text += String(line[run.range].characters)
        }
        return text
    }

    private func isRed(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.sRGB) else {
            return false
        }
        return rgb.redComponent > 0.9 && rgb.greenComponent < 0.1 && rgb.blueComponent < 0.1
    }

    /// Blank lines at both ends of the file come back in place, so the code
    /// between them stays colored at its source line numbers.
    func testBlankLinesAtBothEndsComeBackInPlace() throws {
        let source = "\n\nlet a = 1\nlet b = 2\n\n"
        let html = "\n\n" + red("let") + " a = 1\nlet b = 2\n\n"

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(forHighlightedHTML: html, source: source),
                                  alignedTo: source))

        XCTAssertEqual(lines.map(text), ["", "", "let a = 1", "let b = 2", "", ""])
        XCTAssertEqual(lines.map(redText), ["", "", "let", "", "", ""])
    }

    /// A file whose first line is indented keeps that indentation, and its colors:
    /// output that starts with whitespace is the source itself, not a mismatch.
    func testAFirstLinesIndentationIsKept() throws {
        let source = "    let a = 1\nlet b = 2\n"
        let html = "    " + red("let") + " a = 1\nlet b = 2\n"

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(forHighlightedHTML: html, source: source),
                                  alignedTo: source))

        XCTAssertEqual(lines.map(text), ["    let a = 1", "let b = 2", ""])
        XCTAssertEqual(lines.map(redText), ["let", "", ""])
    }

    /// A CRLF file is highlighted with bare LFs, and every line, down to the
    /// trailing empty one, keeps its source index.
    func testCRLFLinesLineUpWithTheirSource() throws {
        let source = DiffHighlighter.normalizingLineEndings("let a = 1\r\nlet b = 2\r\n")
        XCTAssertEqual(source, "let a = 1\nlet b = 2\n")

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(for: source), alignedTo: source))

        XCTAssertEqual(lines.map(text), ["let a = 1", "let b = 2", ""])
    }

    /// The diff shows a lone CR as a space on the line it sits in, so the text to
    /// highlight does the same, and every line keeps its index.
    func testALoneCRLinesUpAsASpace() throws {
        let source = DiffHighlighter.normalizingLineEndings("let a = 1\rlet b = 2\nlet c = 3\n")
        XCTAssertEqual(source, "let a = 1 let b = 2\nlet c = 3\n")

        let lines = try XCTUnwrap(
            DiffHighlighter.lines(fromLibraryOutput: libraryOutput(for: source), alignedTo: source))

        XCTAssertEqual(lines.map(text), ["let a = 1 let b = 2", "let c = 3", ""])
    }

    /// More lines than the source has cannot be lined up with it, so the file
    /// falls back to neutral rather than miscoloring.
    func testOutputLongerThanTheSourceIsRejected() throws {
        XCTAssertNil(DiffHighlighter.lines(fromLibraryOutput: try attributed([("a\nb\nc", nil)]), alignedTo: "a\nb"))
    }

    /// Output trimmed of the source's leading newline and padded at the end has as
    /// many lines as the source, but every line is shifted: it is rejected.
    func testTrimmedOutputIsRejectedEvenWhenTheLineCountsAgree() throws {
        let source = "\nlet a = 1"
        let output = try attributed([("let a = 1\n", nil)])

        XCTAssertNil(DiffHighlighter.lines(fromLibraryOutput: output, alignedTo: source))
    }

    /// Output that turned a CR into a line break, and dropped the final one, has
    /// as many lines as the source, but they break in other places: it is rejected.
    func testOutputWithACRTurnedIntoALineBreakIsRejectedEvenWhenTheLineCountsAgree() throws {
        let source = "let a = 1\rlet b = 2\n"
        let output = try attributed([("let a = 1\nlet b = 2", nil)])

        XCTAssertNil(DiffHighlighter.lines(fromLibraryOutput: output, alignedTo: source))
    }

    /// A precomposed "é" and an "e" followed by a combining accent are equal
    /// `String`s but not the same scalars: output that matches the source only
    /// canonically is still a changed text, and is rejected.
    func testOutputThatOnlyMatchesTheSourceCanonicallyIsRejected() throws {
        let source = "let caf\u{E9} = 1"
        let output = try attributed([("let cafe\u{301} = 1", nil)])
        XCTAssertEqual(String(output.characters), source)

        XCTAssertNil(DiffHighlighter.lines(fromLibraryOutput: output, alignedTo: source))
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
