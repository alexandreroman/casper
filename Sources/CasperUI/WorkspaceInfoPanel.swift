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

    var body: some View {
        // The real laid-out height, not an estimate:
        // `MarkdownTextView.height(for:width:)` measures on the very TextKit 2
        // engine the hosted view below renders with (see that method's doc
        // comment), so no `onGeometryChange` round-trip through a live view is
        // needed to learn it.
        //
        // Bound once and read by both frames below: measuring renders the whole
        // message and lays it out, which is not work to do twice for one pass.
        let contentHeight = MarkdownTextView.height(for: markdown, width: Self.contentWidth)
        ScrollView {
            MarkdownTextView(markdown: markdown, width: Self.contentWidth, onOpenURL: openURL)
                .frame(width: Self.contentWidth, height: contentHeight)
        }
        .frame(height: min(max(contentHeight, Self.minHeight), Self.maxHeight))
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
