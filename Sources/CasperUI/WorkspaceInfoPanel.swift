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

    /// `MarkdownTextView.height(for:width:)` measures on the very TextKit 2
    /// engine the hosted view below renders with (see that method's doc
    /// comment), so this is the real laid-out height, not an estimate — no
    /// `onGeometryChange` round-trip through a live view is needed to learn it.
    private var contentHeight: CGFloat {
        MarkdownTextView.height(for: markdown, width: Self.contentWidth)
    }

    var body: some View {
        ScrollView {
            MarkdownTextView(markdown: markdown, width: Self.contentWidth, onOpenURL: openURL)
                .frame(width: Self.contentWidth, height: contentHeight)
        }
        .frame(height: min(max(contentHeight, Self.minHeight), Self.maxHeight))
        .padding(Self.padding)
        .frame(width: Self.width)
    }

    /// A published endpoint is almost always local, so an http(s) link opens in
    /// this workspace's own browser panel rather than leaving the app; every
    /// other scheme returns `false` so `NSTextView`'s own system-open handles it.
    ///
    /// Module-visible (not `private`) so `WorkspaceInfoPanelTests` can pin both
    /// branches of the scheme predicate against a real, seeded `AppModel` —
    /// `MarkdownTextViewTests` only drives the coordinator with an injected stub
    /// closure, which decides the outcome itself and never reaches this guard.
    func openURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return model.controlOpenBrowser(url: url, in: workspace.id)
    }
}
