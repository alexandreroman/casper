import AppKit
import SwiftUI

/// The single source of truth for how rendered Markdown looks in this view.
///
/// Both `makeNSView`'s content and the static `height(for:width:)` measurement
/// read these, so a future font change cannot desync the reported height from
/// what actually renders. `NSColor.labelColor` stays dynamic on purpose — it
/// resolves per appearance at draw time, so light/dark both look right.
private enum Style {
    static var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
    static var textColor: NSColor { .labelColor }
}

/// An `NSTextView` that shows the pointing-hand cursor over a `.link` run and
/// the I-beam everywhere else, since AppKit does not do this on its own (see the
/// `nstextview-link-cursor-and-selection` project memory note).
///
/// Follows this app's established convention for chrome that manages its own
/// cursor over/inside an AppKit view (see the `terminal-overlay-cursor` project
/// memory note): a tracking area drives the cursor from BOTH `cursorUpdate(with:)`
/// and `mouseEntered(with:)`, reset on exit, never `push`/`pop`/`addCursorRect`.
/// Not `private`: `MarkdownTextViewTests` casts `makeNSView`'s result to this
/// type and calls `linkURL(at:)` directly, so deleting this class fails the
/// build instead of silently leaving the suite green.
final class LinkCursorTextView: NSTextView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // The panel scrolls inside a SwiftUI `ScrollView`, which reshapes what
        // part of this view is on screen without going through an AppKit
        // `NSClipView` this view's ancestry would recognize, so `.inVisibleRect`
        // cannot track it on its own — the area is rebuilt from `visibleRect`
        // here instead, and AppKit calls this method again whenever that changes.
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: visibleRect,
            // `.activeAlways`, not `.activeInKeyWindow`: the info panel is a
            // popover that is not necessarily the key window while the pointer
            // is over it.
            options: [.cursorUpdate, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { applyCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { applyCursor(for: event) }

    // Also set on entry, not only from `cursorUpdate`/`mouseMoved`: entering
    // from a region that defines no cursor of its own does not reliably
    // redeliver those two (see the `terminal-overlay-cursor` project memory
    // note).
    override func mouseEntered(with event: NSEvent) { applyCursor(for: event) }

    // Reset so the cursor does not leak onto sibling chrome outside this view.
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    /// Pointing hand over a `.link` run, I-beam everywhere else — the text is
    /// selectable, so the I-beam (not the arrow) is the correct resting cursor.
    private func applyCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (linkURL(at: point) != nil ? NSCursor.pointingHand : NSCursor.iBeam).set()
    }

    /// The `.link` attribute, if any, under `point` (in this view's own
    /// coordinate space). `nil` for a point past the last character —
    /// `characterIndexForInsertion(at:)` returns `textStorage.length` there,
    /// which has no attribute run of its own.
    ///
    /// Internal rather than `private` so `MarkdownTextViewTests` exercises this
    /// exact lookup instead of re-implementing it.
    func linkURL(at point: NSPoint) -> URL? {
        guard let textStorage else { return nil }
        let index = characterIndexForInsertion(at: point)
        guard index < textStorage.length else { return nil }
        return textStorage.attribute(.link, at: index, effectiveRange: nil) as? URL
    }
}

/// A read-only, selectable `NSTextView` showing Markdown rendered by
/// `MarkdownAttributedString`.
///
/// **Why AppKit rather than SwiftUI `Text`:** SwiftUI renders a Markdown link as
/// a `.link` attribute inside one `Text`-backed block, with no per-link view to
/// hang an `.onHover` cursor override off — so a selectable block shows the
/// I-beam even over links (see the `nstextview-link-cursor-and-selection` project
/// memory note). `NSTextView` keeps text selection working over that same
/// `.link` attribute, but — confirmed by hand against the running app — does
/// *not* show the pointing-hand cursor over a link on its own; an earlier
/// version of this comment assumed it did, which was wrong. `LinkCursorTextView`
/// below adds that cursor itself, the way this app's other AppKit chrome over a
/// terminal already does (see the `terminal-overlay-cursor` project memory
/// note): a tracking area driving both `cursorUpdate(with:)` and
/// `mouseEntered(with:)`, never `push`/`pop` or `addCursorRect`. Do not fold
/// this view back into a `Text`-based renderer — that would drop both the
/// cursor and text selection.
///
/// **No enclosing `NSScrollView`.** The panel owns scrolling and padding; this
/// view lays out at a fixed `width` and its caller sizes it with
/// `height(for:width:)`.
@MainActor
struct MarkdownTextView: NSViewRepresentable {
    private let markdown: String
    private let width: CGFloat
    /// Called with the clicked URL and the modifier keys held down at the time
    /// of the click, so the caller can route the same link to a different place
    /// depending on them. Returns `true` when the click was handled, which
    /// suppresses `NSTextView`'s own system open; `false` lets the system handle
    /// the URL.
    private let onOpenURL: (URL, NSEvent.ModifierFlags) -> Bool

    init(markdown: String, width: CGFloat, onOpenURL: @escaping (URL, NSEvent.ModifierFlags) -> Bool) {
        self.markdown = markdown
        self.width = width
        self.onOpenURL = onOpenURL
    }

    /// The full laid-out height of `markdown` at `width`, so the caller can give
    /// this view a frame tall enough to show all of it.
    ///
    /// Measured through a throwaway TextKit stack rather than off a live view: a
    /// view's own frame height is whatever was proposed to it, which would make
    /// the answer echo the question.
    ///
    /// That throwaway stack is assembled by hand as `NSTextContentStorage` →
    /// `NSTextLayoutManager` → `NSTextContainer` so it is the **TextKit 2** engine
    /// — the one a plain `NSTextView(frame:)` is backed by, and therefore the one
    /// `makeNSView` really renders with. The TextKit 1 compatibility stack answers
    /// a measurably different height for the same string, most of all around
    /// `NSTextTable`, which is exactly how `MarkdownAttributedString` lays out a
    /// GFM table; measuring on that engine would clip or pad a table in the panel.
    /// The container matches the real view's `lineFragmentPadding = 0` so both
    /// wrap at exactly the same width.
    static func height(for markdown: String, width: CGFloat) -> CGFloat {
        let content = renderedContent(for: markdown, width: width)
        guard content.length > 0 else { return 0 }

        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer
        contentStorage.textStorage?.setAttributedString(content)

        layoutManager.ensureLayout(for: contentStorage.documentRange)
        // TextKit 2's answer to `NSLayoutManager.usedRect(for:)`: the extent the
        // laid-out text actually occupies in the container.
        return ceil(layoutManager.usageBoundsForTextContainer.height)
    }

    /// The rendered Markdown, built at most once per `(markdown, width)` pair.
    ///
    /// The panel measures the message and then renders it, and both go through
    /// the full pipeline — parsing, one pass over every block, a rasterized rule
    /// per thematic break. Sharing one build between the two halves is what
    /// keeps a panel that reopens or re-lays-out from paying for it again.
    ///
    /// Deliberately a single entry rather than a dictionary: only one message is
    /// on screen at a time, so one slot serves every hit this is here for, and a
    /// map keyed by arbitrary user-supplied Markdown could grow without bound.
    private static func renderedContent(for markdown: String, width: CGFloat) -> NSAttributedString {
        if let cached = lastRendered, cached.markdown == markdown, cached.width == width {
            return cached.content
        }
        let content = MarkdownAttributedString.make(
            markdown, font: Style.font, textColor: Style.textColor, contentWidth: width)
        lastRendered = (markdown: markdown, width: width, content: content)
        return content
    }

    /// Main-actor state, like every other member of this view: the two callers
    /// are `height(for:width:)`, reached from a SwiftUI `body`, and
    /// `updateNSView`.
    private static var lastRendered: (markdown: String, width: CGFloat, content: NSAttributedString)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> NSTextView {
        // The TextKit 2 chain, built by hand — the same way `DiffTextSurface`'s
        // `Coordinator.init` assembles its own (see that initializer's comment for
        // why). `NSTextView(frame:)` happens to be TextKit 2-backed today, but
        // that is a default this file would otherwise have to trust rather than
        // guarantee: merely *reading* `NSTextView.layoutManager` anywhere still
        // migrates the view to TextKit 1 and nils out `textLayoutManager` (see the
        // `textkit2-layout-geometry` project memory note), which would desync the
        // render engine from what `height(for:width:)` measures. Constructing the
        // stack explicitly via `NSTextView(frame:textContainer:)` makes TextKit 2
        // an invariant of this view's own container, rather than incidental to
        // which initializer happened to be called.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: 0))
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer

        let textView = LinkCursorTextView(frame: CGRect(x: 0, y: 0, width: width, height: 0), textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // The panel owns the padding around the message, so the text view adds
        // none of its own — neither an inset nor AppKit's default line-fragment
        // padding, which would otherwise make the rendered width `width` + 10.
        textView.textContainerInset = .zero
        // Neither axis resizes itself. The caller (`WorkspaceInfoPanel`) measures
        // the message with `height(for:width:)` and gives this view exactly that
        // frame, so the view must not compute a frame of its own:
        // `isVerticallyResizable = true` let AppKit shrink the assigned frame back
        // to the extent of the text it had lazily laid out (TextKit 2 lays out
        // viewport-first), which silently clipped the tail of a long, scrolling
        // message — measured at a 1000 pt frame against 1263 pt of laid-out text,
        // so its last 263 pt were never drawn.
        //
        // The container stays unbounded in height either way, so nothing is
        // clipped at layout time: it is built above with a 0 height, which
        // TextKit 2 reads as unlimited, and `heightTracksTextView` stays false.
        // Only the width tracks the view, so wrapping happens at `width`.
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        // Still true despite the explicit construction above: nothing past this
        // point may read `textView.layoutManager` (see the comment at the top of
        // this function).
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // SwiftUI reuses the text view but hands over a freshly built struct on
        // every update, so the coordinator's closure is refreshed too — otherwise
        // clicks would keep calling the one captured at realization time.
        context.coordinator.onOpenURL = onOpenURL

        // Replacing the storage drops whatever the reader had selected, so it only
        // happens when the message itself changed, OR when the width it was
        // rendered at did — `MarkdownAttributedString.make` sizes the thematic
        // break's rasterized rule to `contentWidth`, so the same Markdown at a
        // different width needs a fresh build or that rule renders at a stale
        // width. The panel's width is a constant today, so this never fires in
        // practice, but the guard must not silently assume that stays true. The
        // panel re-renders while the popover is open (a live `casper info set`
        // lands as a new body), and every unrelated SwiftUI update in between must
        // leave a selection alone.
        guard context.coordinator.renderedMarkdown != markdown
            || context.coordinator.renderedWidth != width else { return }
        textView.textStorage?.setAttributedString(Self.renderedContent(for: markdown, width: width))
        context.coordinator.renderedMarkdown = markdown
        context.coordinator.renderedWidth = width
    }

    /// Routes link clicks to the injected closure, and remembers what is currently
    /// rendered so `updateNSView` can tell a real content change from a refresh.
    ///
    /// `NSTextViewDelegate` is one of the Cocoa protocols Apple has *not*
    /// annotated `@MainActor`, so the conformance itself has to be spelled
    /// `@MainActor` or Swift 6 rejects it with `#ConformanceIsolation` (see the
    /// `mainactor-isolated-delegate-conformance` project memory note).
    @MainActor
    final class Coordinator: NSObject, @MainActor NSTextViewDelegate {
        var onOpenURL: (URL, NSEvent.ModifierFlags) -> Bool

        /// The Markdown the text storage was last built from; `nil` until the first
        /// update, so even an empty message renders once.
        var renderedMarkdown: String?
        /// The width `renderedMarkdown` was last built at — see `updateNSView`'s
        /// rebuild guard.
        var renderedWidth: CGFloat?

        init(onOpenURL: @escaping (URL, NSEvent.ModifierFlags) -> Bool) {
            self.onOpenURL = onOpenURL
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // A `.link` attribute is allowed to hold a plain string; leave anything
            // that is not a URL to `NSTextView`'s own handling rather than guessing.
            guard let url = link as? URL else { return false }
            return onOpenURL(url, Self.modifiers())
        }

        /// The modifier keys held for the click being delivered right now.
        ///
        /// `clickedOnLink` is one of the AppKit callbacks that does not carry the
        /// originating `NSEvent`, so the flags are read back off the application's
        /// current event — the very mouse-up AppKit is dispatching from, since the
        /// delegate is called synchronously inside its handling. Masked to the
        /// device-independent bits so the raw left/right-key and numeric-pad bits
        /// cannot make an exact-match comparison fail.
        static func modifiers() -> NSEvent.ModifierFlags {
            guard let event = NSApp.currentEvent else { return [] }
            return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
    }
}
