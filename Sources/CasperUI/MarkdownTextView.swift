import AppKit
import SwiftUI

/// The single source of truth for how rendered Markdown looks in this view.
///
/// Both halves of the view reach these through the one `rendered(for:width:)`
/// build, so a future font change cannot desync the reported height from what
/// actually renders. `NSColor.labelColor` stays dynamic on purpose — it resolves
/// per appearance at draw time, so light/dark both look right.
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
    /// Handed the height this view has *actually* laid out, whenever that height
    /// moves. See `reportLaidOutHeight()` for why the caller cannot work this
    /// out for itself.
    var onLaidOutHeight: ((CGFloat) -> Void)?

    /// The last height handed to `onLaidOutHeight`, so an unchanged layout stays
    /// silent — see `reportLaidOutHeight()`.
    private var lastReportedHeight: CGFloat?

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

    /// The one place a real frame and a real layout both exist, which is what
    /// makes it the place to report the laid-out height from.
    ///
    /// `updateNSView` cannot do it: it runs with `frame == .zero` and no window,
    /// and any layout forced from there is thrown away as soon as SwiftUI
    /// assigns the real frame — the container has `widthTracksTextView = true`,
    /// so the 0 → `width` change invalidates every fragment that was laid out at
    /// zero.
    override func layout() {
        super.layout()
        reportLaidOutHeight()
    }

    /// Hands `onLaidOutHeight` the height of the text as the engine currently
    /// driving this view has laid it out.
    ///
    /// **Which engine that is cannot be assumed.** This view is built on the
    /// TextKit 2 stack, but AppKit migrates it to TextKit 1 behind our back on a
    /// display pass once its storage holds a text block — a GFM table or a block
    /// quote, the two shapes `MarkdownAttributedString` renders one for — and the
    /// two engines lay the same string out to different heights (see the
    /// `textkit1-fallback-on-nstexttable` project memory note). So the *live*
    /// stack is asked, and `textLayoutManager` is tested FIRST: merely reading
    /// `layoutManager` is itself what performs that migration, so a fallback
    /// chain starting at TextKit 1 would cause the very migration it means to
    /// detect.
    ///
    /// **The report cannot loop.** A new height changes the frame, and the frame
    /// change brings AppKit back through `layout()`; that second pass computes
    /// the same height, because layout depends on the container's width and
    /// never on the view's height (`heightTracksTextView` stays false), so the
    /// comparison below drops it and the view settles after one round trip.
    /// `MarkdownTextView.updateNSView` clears `lastReportedHeight` whenever it
    /// swaps the storage, so a new message is still reported even if it lays out
    /// to the height the previous one did.
    ///
    /// Forcing layout over the whole document on every pass is affordable here
    /// and nowhere near the diff surface's scale: an info-panel message is one
    /// bounded string, and the panel already lays the same string out once per
    /// body evaluation to measure it.
    private func reportLaidOutHeight() {
        guard let textContainer, let onLaidOutHeight else { return }

        let height: CGFloat
        if let textLayoutManager {
            guard let documentRange = textLayoutManager.textContentManager?.documentRange else { return }
            // TextKit 2 lays out viewport-first, so the usage bounds cover the
            // whole document only once layout has been forced over all of it.
            textLayoutManager.ensureLayout(for: documentRange)
            height = ceil(textLayoutManager.usageBoundsForTextContainer.height)
        } else {
            guard let layoutManager else { return }
            layoutManager.ensureLayout(for: textContainer)
            height = ceil(layoutManager.usedRect(for: textContainer).height)
        }

        guard abs(height - (lastReportedHeight ?? -1)) > 0.5 else { return }
        lastReportedHeight = height
        // Off this layout pass rather than inline: SwiftUI drives AppKit layout
        // from inside its own update, and writing view state there is the
        // classic "modifying state during view update" hazard. The height is
        // already final by the time the hop runs, and the guard above is what
        // keeps the hop from repeating.
        DispatchQueue.main.async { onLaidOutHeight(height) }
    }

    /// Forgets what was last reported, so the next layout pass reports whatever
    /// the current content lays out to even if that matches the previous
    /// content's height.
    func forgetReportedHeight() {
        lastReportedHeight = nil
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
    /// Called with the height the hosted view has really laid out, so the caller
    /// can size it from that instead of from `height(for:width:)` alone — see
    /// `LinkCursorTextView.reportLaidOutHeight()` for why the two can disagree.
    /// Defaulted to a no-op for a caller that pins the view's height itself and
    /// has nothing to do with the answer.
    private let onLaidOutHeight: (CGFloat) -> Void

    init(
        markdown: String, width: CGFloat,
        onOpenURL: @escaping (URL, NSEvent.ModifierFlags) -> Bool,
        onLaidOutHeight: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.markdown = markdown
        self.width = width
        self.onOpenURL = onOpenURL
        self.onLaidOutHeight = onLaidOutHeight
    }

    /// The height `markdown` lays out to at `width`, as an opening height for
    /// the caller's frame.
    ///
    /// An opening height, and one that has to be right the first time: it is
    /// available before any view exists, so it keeps the first layout pass from
    /// being a zero-height one, and an `NSPopover` freezes its content size from
    /// exactly that pass. `measuredHeight(of:width:)` therefore measures on the
    /// engine the live view will end up being laid out with — TextKit 1 for a
    /// message holding a text block, TextKit 2 for every other one. The height
    /// that decides whether a line is *drawn* is still the one the live view
    /// reports, which is why `onLaidOutHeight` exists and why the caller must
    /// take the larger of the two (see
    /// `LinkCursorTextView.reportLaidOutHeight()`).
    ///
    /// Measured through a throwaway TextKit stack rather than off a live view —
    /// see `measuredHeight(of:width:)` — and measured once per message, not once
    /// per call: this is reached from a SwiftUI `body`, so every hover and every
    /// live `casper info set` would otherwise re-lay-out the whole message.
    ///
    /// The application's appearance stands in for the hosted view's, there being no
    /// view to ask yet. The two agree — the panel overrides neither — and they have
    /// to: the shared build is keyed on the appearance, so two different answers
    /// would evict each other's entry on every pass.
    static func height(for markdown: String, width: CGFloat) -> CGFloat {
        rendered(for: markdown, width: width, appearance: NSApp.effectiveAppearance.name).height
    }

    /// The height `content` lays out to at `width` on the TextKit engine that
    /// will really lay the hosted view out, measured through a throwaway stack
    /// rather than off a live view: a view's own frame height is whatever was
    /// proposed to it, which would make the answer echo the question.
    ///
    /// The engine has to be predicted, not assumed. A view whose storage holds a
    /// text block migrates itself from TextKit 2 to TextKit 1 on its first
    /// display pass (see the `textkit1-fallback-on-nstexttable` project memory
    /// note), and the two engines lay the same string out to different heights.
    ///
    /// Deliberately the predicted engine's answer rather than the larger of the
    /// two: the sign of the gap depends on the content — TextKit 1 lays a table
    /// of wrapping cells out taller, and a table of short cells far shorter — so
    /// taking the larger would open the panel with a wide empty band under a
    /// short-celled table. The prediction has to be accurate in both directions;
    /// `WorkspaceInfoPanel`'s `max(measured, reported)` is what keeps the
    /// scrolled document complete if it is ever wrong.
    ///
    /// The prediction is per *message*; the migration is per *view* and one-way.
    /// `updateNSView` reuses a single `LinkCursorTextView` across messages, so
    /// once a message holding a text block has been shown in it, a later message
    /// with none is still laid out by TextKit 1 while this predicts TextKit 2.
    /// Every case measured errs on the over-measuring side — 46 pt predicted
    /// against 33 pt laid out for a thematic break, exact agreement for
    /// spacing-heavy plain paragraphs — so it buys invisible scroll slack
    /// rather than costing a line, and it is reachable only by a message
    /// swapped inside an already-open popover.
    private static func measuredHeight(of content: NSAttributedString, width: CGFloat) -> CGFloat {
        guard content.length > 0 else { return 0 }
        return holdsTextBlock(content)
            ? textKit1Height(of: content, width: width)
            : textKit2Height(of: content, width: width)
    }

    /// Whether `content` carries a text block on any of its paragraph styles,
    /// which is the measured trigger for AppKit migrating a view to TextKit 1.
    ///
    /// Both shapes `MarkdownAttributedString` produces one with are covered: a
    /// GFM table's cells (`renderTableCell`) and a block quote's leading rule
    /// (`blockQuoteRule`).
    private static func holdsTextBlock(_ content: NSAttributedString) -> Bool {
        var found = false
        let wholeString = NSRange(location: 0, length: content.length)
        content.enumerateAttribute(.paragraphStyle, in: wholeString) { value, _, stop in
            guard let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    /// The height `content` lays out to at `width` on a throwaway TextKit 2
    /// stack, assembled by hand as `NSTextContentStorage` → `NSTextLayoutManager`
    /// → `NSTextContainer` so it is the TextKit 2 engine — the one `makeNSView`
    /// builds — with its container matching the real view's
    /// `lineFragmentPadding = 0` so both wrap at exactly the same width.
    private static func textKit2Height(of content: NSAttributedString, width: CGFloat) -> CGFloat {
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

    /// The height `content` lays out to at `width` on a throwaway TextKit 1
    /// stack: `NSTextStorage` → `NSLayoutManager` → `NSTextContainer`, again at
    /// the real view's `lineFragmentPadding = 0`.
    ///
    /// `ensureLayout(for:)` then `usedRect(for:)` is the very pair of calls
    /// `LinkCursorTextView.reportLaidOutHeight()` makes on the live view's
    /// TextKit 1 branch, so the measurement and the report agree by construction.
    private static func textKit1Height(of content: NSAttributedString, width: CGFloat) -> CGFloat {
        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
    }

    /// One message as both halves the view needs it in: the rendered Markdown,
    /// and the height it lays out to at the width it was rendered for.
    private struct Rendered {
        let markdown: String
        let width: CGFloat
        let appearance: NSAppearance.Name
        let content: NSAttributedString
        let height: CGFloat
    }

    /// The rendered Markdown and its measured height, built at most once per
    /// `(markdown, width, appearance)` triple.
    ///
    /// The appearance is part of the key because not every color in the render
    /// stays dynamic: `MarkdownAttributedString` rasterizes a thematic break into
    /// an `NSImage` and bakes the quote and table borders from a resolved
    /// `textColor`, so a build made under one appearance keeps that appearance's
    /// chrome for good.
    ///
    /// The panel measures the message and then renders it, and both go through
    /// the full pipeline — parsing, one pass over every block, a rasterized rule
    /// per thematic break, then a layout pass over the whole document to measure
    /// it. Sharing one build between the two halves is what keeps a panel that
    /// reopens or re-lays-out from paying for it again.
    ///
    /// The height is measured here, alongside the render, rather than on first
    /// ask: the panel's `body` measures every message it renders, so a slot
    /// filled lazily would carry a second mutable state for no work saved.
    ///
    /// Deliberately a single entry rather than a dictionary: only one message is
    /// on screen at a time, so one slot serves every hit this is here for, and a
    /// map keyed by arbitrary user-supplied Markdown could grow without bound.
    private static func rendered(
        for markdown: String, width: CGFloat, appearance: NSAppearance.Name
    ) -> Rendered {
        if let cached = lastRendered, cached.markdown == markdown, cached.width == width,
           cached.appearance == appearance {
            return cached
        }
        let content = MarkdownAttributedString.make(
            markdown, font: Style.font, textColor: Style.textColor, contentWidth: width)
        let entry = Rendered(
            markdown: markdown, width: width, appearance: appearance, content: content,
            height: measuredHeight(of: content, width: width))
        lastRendered = entry
        return entry
    }

    /// Main-actor state, like every other member of this view: the two callers
    /// are `height(for:width:)`, reached from a SwiftUI `body`, and
    /// `updateNSView`.
    private static var lastRendered: Rendered?

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenURL: onOpenURL)
    }

    func makeNSView(context: Context) -> LinkCursorTextView {
        // The TextKit 2 chain, built by hand — the same way `DiffTextSurface`'s
        // `Coordinator.init` assembles its own (see that initializer's comment for
        // why). `NSTextView(frame:)` happens to be TextKit 2-backed today, but
        // that is a default this file would otherwise have to trust rather than
        // ask for, and merely *reading* `NSTextView.layoutManager` anywhere
        // migrates the view to TextKit 1 and nils out `textLayoutManager` (see the
        // `textkit2-layout-geometry` project memory note).
        //
        // What this does NOT buy is TextKit 2 as an invariant: AppKit migrates the
        // view to TextKit 1 by itself, on a display pass, whenever the storage
        // holds a text block — a GFM table or a block quote (see the
        // `textkit1-fallback-on-nstexttable` project memory note) — and nothing
        // here can hold it back. That is why the height this view is given comes
        // from `reportLaidOutHeight()`, which asks whichever engine is live,
        // rather than from `height(for:width:)` alone.
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: 0))
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = textContainer

        let textView = LinkCursorTextView(
            frame: CGRect(x: 0, y: 0, width: width, height: 0), textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.onLaidOutHeight = onLaidOutHeight
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

    func updateNSView(_ textView: LinkCursorTextView, context: Context) {
        // SwiftUI reuses the text view but hands over a freshly built struct on
        // every update, so both closures are refreshed too — otherwise clicks and
        // height reports would keep calling the ones captured at realization time.
        context.coordinator.onOpenURL = onOpenURL
        textView.onLaidOutHeight = onLaidOutHeight

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
        //
        // The appearance is the third input for the same reason the width is: the
        // rasterized rule and the quote/table borders bake a resolved color, so a
        // light↔dark switch leaves them tinted for the appearance they were built
        // under until the storage is rebuilt.
        let appearance = textView.effectiveAppearance.name
        guard context.coordinator.renderedMarkdown != markdown
            || context.coordinator.renderedWidth != width
            || context.coordinator.renderedAppearance != appearance else { return }
        textView.textStorage?.setAttributedString(
            Self.rendered(for: markdown, width: width, appearance: appearance).content)
        // New content, so the previous content's reported height is no longer a
        // reason to stay quiet at the next layout pass.
        textView.forgetReportedHeight()
        context.coordinator.renderedMarkdown = markdown
        context.coordinator.renderedWidth = width
        context.coordinator.renderedAppearance = appearance
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
        /// The appearance `renderedMarkdown` was last built under — see
        /// `updateNSView`'s rebuild guard.
        var renderedAppearance: NSAppearance.Name?

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
        private static func modifiers() -> NSEvent.ModifierFlags {
            guard let event = NSApp.currentEvent else { return [] }
            return event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        }
    }
}
