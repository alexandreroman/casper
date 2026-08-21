import AppKit
import CasperCore
import SwiftUI

/// The content of a workspace's info panel: the latest Markdown message
/// published by `casper info set`, rendered inside the popover anchored to the
/// toolbar's info button.
///
/// The message is arbitrary user content, so the panel is defensive about size:
/// it hugs its content vertically only up to `maxHeight`, then scrolls. Text is
/// selectable so a URL or command can be pulled out of the panel by hand.
struct WorkspaceInfoPanel: View {
    let model: AppModel
    let workspace: Workspace
    let markdown: String

    static let width: CGFloat = 520
    static let maxHeight: CGFloat = 420
    /// Floor under the `ScrollView`'s height so a very short (or empty)
    /// message does not collapse the popover to an unusably thin sliver.
    static let minHeight: CGFloat = 20

    /// The panel's own padding on each side of the scrollable content, kept as
    /// a named constant so the width handed to `MarkdownTextView` is
    /// derived from it rather than a second, easily-drifting magic number.
    private static let padding: CGFloat = 12
    /// The width `MarkdownTextView` actually wraps at once the panel's own
    /// padding is subtracted, fed to both the view and its height measurement
    /// so neither can disagree with the other about where a line wraps.
    private static let contentWidth: CGFloat = width - 2 * padding

    /// Breathing room under the message, applied INSIDE the scrollable content.
    /// `padding` cannot serve this role: it sits outside the `ScrollView`, so it
    /// pads the viewport, never the document. Without this inset the document
    /// ends flush with its last line, and at maximum scroll that line lands
    /// exactly on the viewport's bottom edge — where any sub-point rounding in
    /// the real popover clips it, and where even a clean layout reads as cut
    /// off. Module-visible so `WorkspaceInfoPanelTests` pins the slack against
    /// this constant rather than against a second copy of the number.
    static let contentBottomInset: CGFloat = 8

    /// The height the hosted text view reports having actually laid out, paired
    /// with the message it laid out.
    ///
    /// The pairing is load-bearing: a report arrives a turn after the layout
    /// pass that produced it, so without it a freshly published message could be
    /// sized from the previous one's height for the frame or two before its own
    /// layout pass reports.
    @State private var laidOut: (markdown: String, height: CGFloat)?

    var body: some View {
        // Two answers to "how tall is this message", and the panel must not
        // assume they agree.
        //
        // `MarkdownTextView.height(for:width:)` measures on a throwaway TextKit 2
        // stack. It is available before any view exists, so it is what keeps the
        // first layout pass from being a zero-height one and lets a short message
        // hug its text on first appearance. But the hosted view does not stay on
        // TextKit 2 — AppKit migrates it to TextKit 1 on a display pass once the
        // message contains a GFM table, and TextKit 1 lays the same string out to
        // a different height (see the `textkit1-fallback-on-nstexttable` project
        // memory note). Sizing the view from the measurement alone left the tail
        // of such a message below the frame's bottom edge, clipped by the view's
        // own bounds and therefore undrawn at every scroll offset.
        //
        // So the live view reports what it really laid out, and that supersedes
        // the measurement. The larger of the two rather than "the report wins":
        // both numbers are lower bounds on what has to be drawn, and the two
        // failure modes are not symmetric — a frame taller than the text buys a
        // few points of invisible scroll slack, while a frame shorter than it
        // silently eats lines. `max` also makes this a pure widening of what the
        // panel did before: the frame can never come out shorter than the
        // measurement it used to be pinned to.
        //
        // Bound once and read by both frames below: measuring renders the whole
        // message and lays it out, which is not work to do twice for one pass.
        let measuredHeight = MarkdownTextView.height(for: markdown, width: Self.contentWidth)
        let reportedHeight = laidOut.flatMap { $0.markdown == markdown ? $0.height : nil }
        let contentHeight = max(measuredHeight, reportedHeight ?? 0)
        let viewportHeight = min(max(contentHeight, Self.minHeight), Self.maxHeight)
        ScrollView {
            MarkdownTextView(
                markdown: markdown, width: Self.contentWidth, onOpenURL: openURL,
                onLaidOutHeight: { laidOut = (markdown, $0) })
                .frame(width: Self.contentWidth, height: contentHeight)
                .padding(.bottom, Self.contentBottomInset)
        }
        // The inset deliberately does NOT go into the height below: it belongs
        // to the scrolled document, not to the viewport. Adding it here too
        // would grow the panel around a message that already fits, hanging an
        // empty band under a one-line message on top of the outer padding. A
        // message that fits therefore just carries a few points of scroll slack
        // past its end, which is invisible at rest.
        //
        // A CAP, not a pinned height. `idealHeight` is the hug/cap size the
        // panel asks for when nothing constrains it; `maxHeight` lets the
        // `ScrollView` yield to a host with less room to offer instead of
        // overflowing it. A pinned `height:` hangs the viewport's bottom outside
        // such a host, and every point hanging out is unreachable at any scroll
        // offset — the tail of the message can then never be read at all.
        .frame(idealHeight: viewportHeight, maxHeight: viewportHeight)
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    /// Holding this while clicking a link sends it to the system's default
    /// browser instead of the workspace's own browser panel.
    ///
    /// Command, because that is the macOS convention for "same click, other
    /// destination" and it is the one modifier `NSTextView` does not already
    /// spend on a click of its own: Shift extends the selection, Control opens
    /// the context menu, and Option starts a rectangular selection.
    static let systemBrowserModifier: NSEvent.ModifierFlags = .command

    /// Where a clicked link goes, as a value, so the routing rule can be pinned
    /// by tests without any of the three outcomes actually being performed.
    enum LinkDestination: Equatable {
        /// This workspace's own browser panel.
        case workspaceBrowser
        /// The system's default browser, via `NSWorkspace`.
        case systemBrowser
        /// Not ours to open — `NSTextView`'s own system-open handles it.
        case system
    }

    /// A published endpoint is almost always local, so a plain click on an
    /// http(s) link opens in this workspace's own browser panel rather than
    /// leaving the app; holding `systemBrowserModifier` overrides that and hands
    /// the URL to the default browser. Every other scheme is left to the system
    /// either way — those already open outside the app, so the modifier has
    /// nothing to switch between.
    static func destination(for url: URL, modifiers: NSEvent.ModifierFlags) -> LinkDestination {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .system
        }
        return modifiers.contains(systemBrowserModifier) ? .systemBrowser : .workspaceBrowser
    }

    /// Performs what `destination(for:modifiers:)` decided, returning `true` when
    /// the click was handled here and `false` to let `NSTextView`'s own
    /// system-open take it.
    ///
    /// Module-visible (not `private`) so `WorkspaceInfoPanelTests` can pin the
    /// workspace-browser branch against a real, seeded `AppModel` —
    /// `MarkdownTextViewTests` only drives the coordinator with an injected stub
    /// closure, which decides the outcome itself and never reaches this method.
    func openURL(_ url: URL, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        switch Self.destination(for: url, modifiers: modifiers) {
        case .system:
            return false
        case .systemBrowser:
            return NSWorkspace.shared.open(url)
        case .workspaceBrowser:
            return model.controlOpenBrowser(url: url, in: workspace.id)
        }
    }
}
