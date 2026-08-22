import AppKit
import Foundation
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// End-to-end guard that an OSC 52 clipboard read emitted by the terminal's own output
/// actually reaches `GhosttyClipboardRead`'s confirmation gate.
///
/// The unit tests in `GhosttyClipboardTests` drive `resolveUntrusted` directly, so they stay
/// green even when nothing in production ever calls it. That is not hypothetical: completing
/// the read request with `confirmed: true` tells libghostty "the user already approved this",
/// which short-circuits its `clipboard-read` policy so `confirm_read_clipboard_cb` never
/// fires and the gate becomes unreachable. Only a real surface, a real PTY and a real OSC 52
/// sequence can tell the two apart — hence the probe below, whose load-bearing assertion is
/// that the gate was *consulted at all*.
///
/// Runs on the shared `withRealSurface` harness — the `.forTesting()` runtime never
/// creates a surface.
final class GhosttyClipboardReadE2ETests: XCTestCase {
    /// The clipboard content the terminal is made to ask for. Distinctive enough that finding
    /// it in the terminal grid cannot be a coincidence.
    private static let marker = "CASPER-OSC52-MARKER-9d41"

    /// The frame the probe prints its answer inside, so the assertions match an exact
    /// `CASPER52[…]END` shape rather than a loose substring.
    private static let answerOpen = "CASPER52["
    private static let answerClose = "]END"

    /// The line the probe prints for an answer of `text`.
    private static func framedAnswer(_ text: String) -> String {
        "\(answerOpen)\(text)\(answerClose)"
    }

    /// A denied OSC 52 read pins the whole gate: the confirmation is consulted (proving the
    /// policy was not short-circuited by a `confirmed: true` completion), the clipboard never
    /// reaches the terminal grid, and the asking program still gets an answer — an empty one —
    /// instead of blocking forever on a request nobody resolved.
    @MainActor
    func testDeniedOSC52ReadConsultsTheGateAndHandsBackNothing() throws {
        let outcome = try runOSC52ReadProbe(approving: false)

        XCTAssertEqual(
            outcome.consulted, [Self.marker],
            """
            the OSC 52 read gate was not consulted — libghostty's clipboard-read policy was \
            short-circuited, so no prompt can ever be raised; grid was:
            \(outcome.grid)
            """)
        XCTAssertFalse(
            outcome.grid.contains(Self.marker),
            "a denied OSC 52 read leaked the clipboard to the terminal; grid was:\n\(outcome.grid)")
        XCTAssertTrue(
            outcome.grid.contains(Self.framedAnswer("")),
            "the denied read never came back, leaving the program waiting; grid was:\n\(outcome.grid)")
    }

    /// An approved OSC 52 read hands the clipboard to the terminal. This is the counterweight
    /// to the denied case: it proves the gate is a decision point rather than a blanket block
    /// that broke clipboard reads outright.
    @MainActor
    func testApprovedOSC52ReadConsultsTheGateAndHandsBackTheClipboard() throws {
        let outcome = try runOSC52ReadProbe(approving: true)

        XCTAssertEqual(
            outcome.consulted, [Self.marker],
            """
            the OSC 52 read gate was not consulted — libghostty's clipboard-read policy was \
            short-circuited, so no prompt can ever be raised; grid was:
            \(outcome.grid)
            """)
        XCTAssertTrue(
            outcome.grid.contains(Self.framedAnswer(Self.marker)),
            "an approved OSC 52 read did not reach the terminal; grid was:\n\(outcome.grid)")
    }

    // MARK: - The probe

    /// What one run of the probe observed.
    private struct ReadOutcome {
        /// The texts the confirmation gate was consulted with, in order. Empty means the gate
        /// never ran — the regression this whole file exists to catch.
        let consulted: [String]
        /// The terminal's visible grid once the probe script finished.
        let grid: String
    }

    /// Put the marker on a pasteboard of the test's own, make a real shell emit an OSC 52
    /// read, answer it with `approving`, and report what the gate saw and what the terminal
    /// ended up showing.
    @MainActor
    private func runOSC52ReadProbe(approving: Bool) throws -> ReadOutcome {
        var consulted: [String] = []
        let productionApproval = GhosttyClipboardRead.approveUntrusted
        let productionPasteboard = GhosttyClipboardRead.systemPasteboard
        // Both are statics: leaking either would disarm the gate for every later test in this
        // process, and the resulting failure would surface far from its cause.
        defer {
            GhosttyClipboardRead.approveUntrusted = productionApproval
            GhosttyClipboardRead.systemPasteboard = productionPasteboard
        }
        GhosttyClipboardRead.approveUntrusted = { text in
            consulted.append(text)
            return approving
        }
        let pasteboard = Self.pasteboardHoldingTheMarker()
        // A named pasteboard outlives the process on the pasteboard server unless released.
        defer { pasteboard.releaseGlobally() }
        GhosttyClipboardRead.systemPasteboard = pasteboard

        let script = try Self.writeProbeScript()
        defer { try? FileManager.default.removeItem(at: script) }

        var grid = ""
        try withRealSurface { view, surface in
            // Let the shell reach an interactive prompt before typing.
            settle(0.6)
            surface.sendText("sh \(script.path)")
            settle(0.4)
            view.keyDown(with: Self.returnKeyEvent())
            // Long enough for the script's own read timeout, plus the main-queue hop the OSC 52
            // prompt is deferred onto.
            settle(4.0)

            grid = surface.readText(scrollback: false) ?? ""
        }

        return ReadOutcome(consulted: consulted, grid: grid)
    }

    /// A pasteboard of the test's own, so the probe never reads — nor disturbs — the
    /// developer's clipboard.
    @MainActor
    private static func pasteboardHoldingTheMarker() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("casper.tests.clipboard-read.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        return pasteboard
    }

    /// Write the shell-side probe: it asks the terminal for the clipboard and prints whatever
    /// answer comes back on its own stdin, decoded and framed.
    ///
    /// A script file rather than a typed one-liner because the surface spawns the developer's
    /// login shell, and quoting escape sequences portably across sh/zsh/fish is a trap; `sh
    /// <path>` types the same in all of them.
    private static func writeProbeScript() throws -> URL {
        let script = #"""
            #!/bin/sh
            # Ask the terminal for the clipboard with an OSC 52 read (the `?` payload). Echo is
            # off while the answer arrives, so the only route the clipboard has into the grid is
            # the framed line printed at the end.
            old=$(stty -g)
            stty raw -echo
            printf '\033]52;c;?\007'
            # The answer carries no newline, so read whatever shows up and then give up: a denied
            # read answers with nothing, and the probe must finish rather than hang on it.
            reply=$(dd bs=1 count=256 2>/dev/null <&0 & pid=$!; sleep 2; kill $pid 2>/dev/null; wait $pid 2>/dev/null)
            stty "$old"
            # Strip the `ESC ] 52 ; c ;` prefix and the `ESC \` (ST) terminator, then un-base64.
            answer=$(printf '%s' "${reply#*;c;}" | tr -d '\033\\' | base64 -D 2>/dev/null)
            printf '\n\#(answerOpen)%s\#(answerClose)\n' "$answer"
            """#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-osc52-probe-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Return keystroke as a real keyboard reports it. `sendText("\r")` is the bulk-text
    /// path, which libghostty does not treat as Return, so the typed command would never run.
    private static func returnKeyEvent() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }
}
