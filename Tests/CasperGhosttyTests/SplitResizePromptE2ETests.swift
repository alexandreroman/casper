import AppKit
import CasperTestSupport
import Foundation
import XCTest

@testable import CasperGhostty

/// Regression tests guarding that exactly one prompt survives a split divider drag or a
/// single resize.
///
/// A Powerlevel10k-style zsh prompt — OSC 133 semantic-prompt marks around a two-line
/// prompt whose first line spans the full terminal width — is redrawn by zsh on every
/// SIGWINCH. libghostty must clear the old prompt before that redraw; otherwise every
/// resize leaves a stale copy of the prompt's first line behind, and a divider drag,
/// which resizes dozens of times, piles them up across the pane.
///
/// The clear happens in upstream Ghostty's `Screen.resize`, after the column reflow. The
/// reflow copies the row's prompt mark onto every row it splits the line into, so the
/// clear must start from the prompt's first row, not from a copied mark. Upstream Ghostty
/// commit 8ad3f607f (#15199) is the fix these tests guard.
///
/// The drag test mimics a divider drag (many small width changes with a tiny run-loop
/// pump between them); the single-resize test resizes once to the same final width, so
/// the two can be told apart.
final class SplitResizePromptE2ETests: XCTestCase {
    private static let startWidth: CGFloat = 800
    private static let endWidth: CGFloat = 450
    private static let height: CGFloat = 600

    @MainActor
    func testDividerDragLeavesOnePrompt() throws {
        let steps = 40
        try assertOnePromptAfterResizing(minimumSizePushes: steps) { view in
            for step in 1...steps {
                let progress = CGFloat(step) / CGFloat(steps)
                let width = Self.startWidth - (Self.startWidth - Self.endWidth) * progress
                resize(view, toWidth: width.rounded())
                settle(0.015)
            }
        }
    }

    @MainActor
    func testSingleResizeLeavesOnePrompt() throws {
        try assertOnePromptAfterResizing(minimumSizePushes: 1) { view in
            resize(view, toWidth: Self.endWidth)
        }
    }

    // MARK: Helpers

    /// Start the p10k-like zsh in a real surface, let it draw its prompt, run `resizing`,
    /// then assert that a single prompt remains on screen.
    ///
    /// `minimumSizePushes` guards that the resize path was actually exercised: without it,
    /// a resize that never reached libghostty would leave one prompt and pass vacuously.
    @MainActor
    private func assertOnePromptAfterResizing(
        minimumSizePushes: Int,
        resizing: (GhosttySurfaceView) -> Void
    ) throws {
        let zdotdir = try writePromptZshrc()
        // `exec env` so the test runs the same zsh whatever the host's login shell is.
        let configuration = GhosttySurfaceConfiguration(
            initialInput: "exec env ZDOTDIR='\(zdotdir.path)' zsh -i\n")

        try withRealSurface(makeView: { GhosttySurfaceView(runtime: $0, configuration: configuration) }) {
            view, surface in
            settle(1.5)  // let zsh start and draw its first prompt
            let pushesBefore = view.debugSizePushCount

            resizing(view)
            settle(1.5)  // let zsh redraw after the last SIGWINCH

            XCTAssertGreaterThanOrEqual(
                view.debugSizePushCount - pushesBefore, minimumSizePushes,
                "the resize never reached libghostty, so the prompt redraw was not exercised")

            let screen = surface.readText(scrollback: true) ?? ""
            // Count occurrences, not lines: the read-back joins soft-wrapped rows into one
            // logical line, so stale prompt copies can share a single "line".
            let promptCount = occurrences(of: "PROMPTTOP", in: screen)
            XCTAssertEqual(promptCount, 1, "expected exactly one prompt on screen; screen was:\n\(screen)")
        }
    }

    /// Resize the harness window's content; the surface view is the content view, so
    /// AppKit resizes it through `setFrameSize`, which pushes the new size to libghostty.
    @MainActor
    private func resize(_ view: GhosttySurfaceView, toWidth width: CGFloat) {
        view.window?.setContentSize(NSSize(width: width, height: Self.height))
    }

    private func occurrences(of marker: String, in text: String) -> Int {
        text.components(separatedBy: marker).count - 1
    }

    /// A temporary ZDOTDIR whose `.zshrc` sets a minimal p10k-like prompt: an OSC 133 A
    /// mark, a first line padded to exactly `$COLUMNS` (`PROMPTTOP` left, `RIGHTEND`
    /// right), then `❯ ` and an OSC 133 B mark. `prompt_subst` re-evaluates the padding
    /// on every redraw, so the first line tracks the width after each resize.
    private func writePromptZshrc() throws -> URL {
        let directory = makeTemporaryDirectory(prefix: "casper-split-resize-zdotdir")
        // `${(r:COLUMNS-8:)${:-PROMPTTOP}}` right-pads PROMPTTOP with spaces to
        // COLUMNS-8 cells, so the 8-cell RIGHTEND ends in the last column.
        let zshrc = #"""
            export LANG=en_US.UTF-8
            setopt prompt_subst
            PROMPT_EOL_MARK=''
            PROMPT=$'%{\e]133;A\a%}${(r:COLUMNS-8:)${:-PROMPTTOP}}RIGHTEND\n❯ %{\e]133;B\a%}'
            """#
        try zshrc.write(to: directory.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        return directory
    }
}
