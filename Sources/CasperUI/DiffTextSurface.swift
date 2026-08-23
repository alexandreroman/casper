import AppKit
import CasperCore
import SwiftUI

/// Where the reader is, in terms that survive the diff being recomputed: which
/// file sits at the top of the viewport, and how far into it they have scrolled.
///
/// Anchored on a file rather than on a `y`, because a refresh rewrites the whole
/// document: a line added anywhere above moves every offset below it, while a
/// file's identity does not move at all.
struct DiffScrollAnchor: Equatable, Sendable {
    /// `DiffDocument.FileSpan.id`, stable across successive diff computations.
    let fileID: String
    /// Distance in points from that file's reserved header band down to the
    /// viewport's top edge.
    let offsetInFile: CGFloat
}

/// The handle `DiffSurfaceView` holds so it can drive the AppKit surface across
/// SwiftUI view-value churn.
///
/// The reference is weak because the coordinator belongs to SwiftUI's
/// representable context: the surface lives exactly as long as the hosted view,
/// and a strong reference here would keep a detached AppKit tree alive after it.
@MainActor
final class DiffSurfaceController {
    weak var coordinator: DiffTextSurface.Coordinator?

    #if DEBUG
    // Spelled out only so the memory census sees every controller; the body is
    // otherwise the implicit `init()`.
    init() { LiveObjectCensus.track(self) }
    #endif
}

/// One revision of the diff, everything needed to paint it from scratch.
///
/// This travels into `DiffTextSurface` as a **property**, not through
/// `DiffSurfaceController`: the coordinator only exists once SwiftUI realizes
/// the representable, so a document produced before that has nothing to push to.
/// As a property it cannot be missed — SwiftUI calls `updateNSView` on
/// realization and on every update after it — which makes the first paint
/// independent of when `.onAppear` happens to run.
struct DiffRendering {
    /// Bumped once per document swap, and the only thing the surface compares.
    /// `updateNSView` runs on every SwiftUI update while `DiffDocument` holds the
    /// entire diff text, so comparing the documents themselves would walk the
    /// whole diff for nothing.
    let revision: Int
    let document: DiffDocument
    /// Syntax highlights carried over from the previous diff, painted right after
    /// the swap: `DiffTextAssembly` builds the fresh storage from base attributes
    /// only, and the files these belong to are deliberately not re-highlighted.
    ///
    /// Paint them through `highlightsInDocumentOrder`, never by iterating this
    /// dictionary — the order is what keeps the paint from freezing the app.
    let highlights: [String: DiffFileHighlight]

    /// The carried highlights to paint, paired with the index of the file they
    /// belong to, in document order.
    ///
    /// The order is the fix for a freeze, not tidiness. `NSTextStorage` keeps its
    /// attributes in a run-length array, and `DiffTextAssembly.applyHighlight`
    /// writes one `.foregroundColor` run per syntax run: painting a file that sits
    /// mid-document therefore memmoves every run belonging to the files below it.
    /// Ascending file order only ever appends, which is linear in the diff's total
    /// run count; `highlights`' own hash order is arbitrary, which makes the same
    /// work quadratic. Measured on a synthetic diff, document order held flat at
    /// 0.23 µs per run — 0.21 s for 64 files — while hash order quadrupled per
    /// doubling of the file count and took 52 s for those same 64 files, with the
    /// main thread spinning inside `_platform_memmove` throughout.
    ///
    /// Walking the document rather than sorting the dictionary is what makes the
    /// order monotonic by construction: files carrying no highlight drop out, and a
    /// highlight naming a file this document doesn't have — one that finished just
    /// after it left the diff — is never looked at.
    var highlightsInDocumentOrder: [(fileIndex: Int, highlight: DiffFileHighlight)] {
        var ordered: [(fileIndex: Int, highlight: DiffFileHighlight)] = []
        for (fileIndex, file) in document.files.enumerated() {
            guard let highlight = highlights[file.id] else { continue }
            ordered.append((fileIndex: fileIndex, highlight: highlight))
        }
        return ordered
    }
}

/// The diff's rendering surface: a scroll view over one TextKit 2 text view, with
/// the gutter ruler beside it and the pinned file header above it.
///
/// The scroll view takes its size from the panel and negotiates **nothing** with
/// SwiftUI — no lazy stack, no pinned sections, no scroll-position binding. Every
/// input arrives through the coordinator's imperative API, one way, so a refresh
/// can never turn into a SwiftUI state write during layout. That feedback path is
/// what the row-based renderer hung on.
struct DiffTextSurface: NSViewRepresentable {
    let controller: DiffSurfaceController
    /// What to render. One-way, SwiftUI to AppKit — no state is written back
    /// during layout, which is the feedback path this renderer exists to remove.
    let rendering: DiffRendering

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        controller.coordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> DiffSurfaceContainerView {
        context.coordinator.containerView
    }

    func updateNSView(_ containerView: DiffSurfaceContainerView, context: Context) {
        // Re-linked so a `DiffSurfaceView` handed a fresh controller still reaches
        // its surface for the scroll targets and highlights that arrive that way.
        controller.coordinator = context.coordinator
        context.coordinator.render(rendering)
    }

    /// Owns the AppKit chain and exposes the narrow imperative API
    /// `DiffSurfaceView` drives it with.
    ///
    /// `@MainActor` both because it lives among AppKit views and because
    /// `DiffTextAssembly` and `DiffFragmentGeometry` are: live TextKit layout is
    /// main-thread-only.
    @MainActor
    final class Coordinator {
        let textView: DiffTextView
        let gutter: DiffGutterRuler
        let stickyHeader: DiffStickyHeader
        let scrollView: NSScrollView
        let containerView: DiffSurfaceContainerView

        /// The viewport. Its `bounds.origin.y` is the surface's scroll position;
        /// `bounds.origin.x` is *not* zero when a ruler is visible, so no `x`
        /// arithmetic here assumes it is.
        var clipView: NSClipView { scrollView.contentView }

        /// The document currently in the text storage — the one every span the
        /// chrome draws from belongs to.
        private(set) var document: DiffDocument?

        /// `DiffRendering.revision` of the document in the text storage; `0`
        /// before the first one lands. Nothing else may render a document, or the
        /// surface would disagree with what this says it is showing.
        private(set) var appliedRevision = 0

        /// The single reader of TextKit layout, rebuilt per call: it is a value over
        /// the layout manager and the current document, so holding one would only
        /// risk pairing a document with a storage it was not assembled from.
        var geometry: DiffFragmentGeometry? {
            guard let document, let layoutManager = textView.textLayoutManager else { return nil }
            return DiffFragmentGeometry(layoutManager: layoutManager, document: document)
        }

        // `nonisolated(unsafe)` so the plain `deinit` below can read it without a
        // main-actor hop: it is only ever written in `init`, no other reference to
        // the object exists by the time `deinit` runs, and
        // `NotificationCenter.removeObserver` is itself thread-safe. An `isolated
        // deinit` would compile but SIGABRTs under XCTest on CI through its
        // back-deployment shim (see the isolated-deinit-ci-sigabrt memory note).
        private nonisolated(unsafe) var boundsObserver: NSObjectProtocol?

        init() {
            // The TextKit 2 chain, built by hand. `NSTextView` would make one
            // itself, but merely *reading* `NSTextView.layoutManager` anywhere
            // migrates the view to TextKit 1 and nils out `textLayoutManager`,
            // silently taking every geometry call with it. Assembling the stack
            // explicitly means TextKit 2 is guaranteed rather than incidental.
            let contentStorage = NSTextContentStorage()
            let layoutManager = NSTextLayoutManager()
            let container = NSTextContainer(
                size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            contentStorage.addTextLayoutManager(layoutManager)
            layoutManager.textContainer = container

            textView = DiffTextView(frame: .zero, textContainer: container)
            // Selectable but not editable: character-level selection and copy are a
            // goal of this rewrite, and the numbers living in the ruler is what makes
            // a copy come out as clean code.
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .textBackgroundColor
            // Grows vertically with the document, never horizontally: the container
            // tracks the view's width, so the text wraps to the panel instead of
            // scrolling sideways.
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.minSize = .zero
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            // The first file's reserved header band. TextKit ignores
            // `paragraphSpacingBefore` on the document's very first paragraph, so the
            // band that file's bar draws into can only come from the inset.
            textView.textContainerInset = NSSize(width: 0, height: DiffTextAssembly.headerBandHeight)
            container.widthTracksTextView = true

            scrollView = NSScrollView()
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.documentView = textView

            gutter = DiffGutterRuler(scrollView: scrollView, textView: textView)
            scrollView.hasVerticalRuler = true
            scrollView.verticalRulerView = gutter
            scrollView.rulersVisible = true

            stickyHeader = DiffStickyHeader(frame: .zero)
            containerView = DiffSurfaceContainerView(scrollView: scrollView, stickyHeader: stickyHeader)
            // How many bands the viewport shows depends on its height, so a resize
            // — including the very first one, which lands after SwiftUI has already
            // pushed a document in — has to re-resolve the bars.
            //
            // The forcing variant, and it has to be. This fires from the
            // *container's* own `layout()`, at a point where the viewport it has
            // just tiled reaches further into the document than TextKit's real
            // layout does; every band past that point is cold, and the non-forcing
            // walk stops at the first cold one. A viewport showing twelve one-line
            // files then carries a single bar instead of one per band —
            // `DiffTextSurfaceTests.testEveryBandOnScreenCarriesItsOwnBar`, which
            // is what a swap to `scheduleStickyHeaderUpdate()` fails on.
            //
            // Laying out from here is also safe, which is what separates it from
            // the hook below: the pass in progress is this container's, and the
            // text view lays itself out afterwards, so `ensureLayout` re-enters
            // nothing.
            containerView.viewportDidChange = { [weak self] in self?.resolveBarsOverTheViewport() }
            // The third thing that invalidates the bars, and the only one the
            // surface does not do to itself: TextKit replacing the estimated
            // geometry the bars were resolved from with real layout. Coalesced, and
            // deliberately *not* `resolveBarsOverTheViewport()` — this one fires
            // from inside `DiffTextView.layout()`, so the layout it would force is
            // the very pass that is settling.
            textView.didLayout = { [weak self] in self?.scheduleStickyHeaderUpdate() }

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            // `queue: nil` delivers on the posting thread — the main thread, since
            // this is a clip view scrolling — and delivers *synchronously*. Hopping
            // through `.main` would leave the bar one frame behind the text it
            // labels, which reads as the header sliding loose while scrolling.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStickyHeader() }
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }

        /// Renders one revision of the diff, at most once.
        ///
        /// SwiftUI calls this on every update of the enclosing view, so an
        /// already-rendered revision has to be a cheap no-op: rebuilding the text
        /// storage for a document that is already on screen is pure waste, and it
        /// would drop the reader's selection along the way.
        func render(_ rendering: DiffRendering) {
            guard rendering.revision != appliedRevision else { return }
            appliedRevision = rendering.revision
            // The anchor is read here, immediately before the swap: applying
            // rewrites the whole text storage, so where the reader is has to come
            // off the live surface first.
            apply(document: rendering.document, restoring: currentAnchor())
            // In document order, which is the difference between a paint that is
            // linear in the diff's run count and one that is quadratic — see
            // `DiffRendering.highlightsInDocumentOrder`.
            if let storage = textView.textContentStorage?.textStorage {
                DiffTextAssembly.applyHighlights(
                    rendering.highlightsInDocumentOrder, in: storage,
                    document: rendering.document)
            }
        }

        /// Replaces the rendered document, putting the reader back where `anchor`
        /// says they were — at the top when that file has left the diff.
        ///
        /// The ordering is load-bearing, not tidiness. The gutter's width is a
        /// property of the document; a new `ruleThickness` retiles the scroll view,
        /// which changes the text container's width, which rewraps the whole
        /// document. Any `y` computed before that is stale, so the document goes in
        /// and the scroll view tiles *before* the anchor is resolved.
        func apply(document: DiffDocument, restoring anchor: DiffScrollAnchor?) {
            self.document = document
            textView.textContentStorage?.textStorage?
                .setAttributedString(DiffTextAssembly.makeAttributedText(for: document))
            textView.document = document
            // Reflows the column's width itself, from its own setter.
            gutter.document = document
            stickyHeader.document = document
            scrollView.tile()

            restore(anchor)
            resolveBarsOverTheViewport()
        }

        /// Lays the viewport out and re-resolves the pinned bars over it.
        ///
        /// The overlay only ever reads geometry TextKit already holds — its own
        /// path may force none — so it needs the viewport laid out first. The two
        /// invalidations the surface causes itself are here: a document swap, after
        /// which no draw has happened yet, and a viewport resize, which can arrive
        /// after the swap because SwiftUI pushes the document in `updateNSView` and
        /// sizes the view afterwards.
        ///
        /// Neither is the last word on where the bars go. What this lays out starts
        /// wherever TextKit's real layout had reached, so past that point the
        /// viewport's fragments are placed over *estimated* heights, and the text
        /// view's next layout pass moves them — which is what
        /// `scheduleStickyHeaderUpdate()` is for.
        private func resolveBarsOverTheViewport() {
            geometry?.ensureLayout(in: visibleRectInContainer)
            updateStickyHeader()
        }

        /// Queues one re-resolution of the pinned bars, and collapses a burst of
        /// layout passes into it.
        ///
        /// Casper recomputes the diff on every file change, and each refresh
        /// invalidates TextKit's layout several times over — the storage swap, then
        /// every carried and progressive highlight painted into it — so the layout
        /// passes that answer those invalidations arrive in bursts. Re-resolving
        /// costs a `DiffFragmentGeometry.fileIndex(atY:)` point probe, which is
        /// O(scroll offset) and 1.17 ms near the bottom of a 20 000-line diff, and
        /// only the last pass of a burst has the settled geometry — so paying it per
        /// pass would burn the time for answers that are thrown away.
        ///
        /// `MainRunLoop.perform` rather than `DispatchQueue.main.async`: a main queue
        /// block does not run while a modal session or a menu is tracking (see the
        /// `main-queue-starved-by-modal-loops` memory note), which would leave the
        /// bars stale for as long as one of those is up.
        ///
        /// The cost of coalescing is that the bars can be one run-loop turn behind
        /// the layout that moved them — the same tolerance `DiffStickyHeader`'s own
        /// walk already takes for a band that has just come into view, and for the
        /// same reason: a turn is not something a reader can see.
        private func scheduleStickyHeaderUpdate() {
            guard !stickyHeaderUpdateIsPending else { return }
            stickyHeaderUpdateIsPending = true
            MainRunLoop.perform { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Cleared before the work, not after: a layout pass provoked
                    // from inside the update has to be able to queue the next one
                    // rather than be swallowed by a flag that is still set.
                    self.stickyHeaderUpdateIsPending = false
                    self.updateStickyHeader()
                }
            }
        }

        /// Whether a re-resolution is already queued. One block in flight at a
        /// time, so a burst of layout passes queues exactly one.
        private var stickyHeaderUpdateIsPending = false

        /// Paints one file's syntax colors into the live text storage.
        ///
        /// Unknown file IDs are ignored rather than reported: highlighting runs
        /// concurrently with refreshes, so a file finishing just after it left the
        /// diff is ordinary.
        func applyHighlight(_ highlight: DiffFileHighlight, forFileID fileID: String) {
            guard let fileIndex = document?.fileIndex(withID: fileID) else { return }
            applyHighlight(highlight, forFileAt: fileIndex)
        }

        /// Paints one file's syntax colors, for a caller that already knows where
        /// that file sits — the whole-document repaint, which walks the files in
        /// order precisely so it never has to look an index up.
        func applyHighlight(_ highlight: DiffFileHighlight, forFileAt fileIndex: Int) {
            guard let document, let storage = textView.textContentStorage?.textStorage
            else { return }
            DiffTextAssembly.applyHighlight(
                highlight, forFileAt: fileIndex, in: storage, document: document)
        }

        /// Scrolls the file's header band to the viewport's top edge, reporting
        /// whether it could. It cannot when the rendered document doesn't hold
        /// that file — a stale target, or one matched against a diff whose
        /// document is still one SwiftUI update away from the surface.
        ///
        /// The target is usually far below what TextKit has laid out, which the
        /// forcing `top(ofFileAt:)` settles outright — where the row-based
        /// renderer deferred a run-loop turn and hoped the row existed by then.
        @discardableResult
        func scroll(toFileID fileID: String) -> Bool {
            guard let document, let geometry, let fileIndex = document.fileIndex(withID: fileID)
            else { return false }
            guard let top = geometry.top(ofFileAt: fileIndex) else { return false }
            scroll(toContainerY: top)
            return true
        }

        /// Where the reader is now, for a later `apply(document:restoring:)` to
        /// restore. `nil` before the first document arrives, or when the viewport's
        /// top edge resolves to no file at all.
        func currentAnchor() -> DiffScrollAnchor? {
            guard let document, let geometry else { return nil }
            let visibleTop = visibleTopInContainer
            guard let fileIndex = geometry.fileIndex(atY: visibleTop),
                  let top = geometry.top(ofFileAt: fileIndex)
            else { return nil }
            return DiffScrollAnchor(
                fileID: document.files[fileIndex].id, offsetInFile: visibleTop - top)
        }

        /// Puts the reader back where `currentAnchor()` left them in the freshly
        /// swapped document. Anything the new document no longer holds — the
        /// anchor's file, or a top the forcing `top(ofFileAt:)` still can't
        /// produce — falls back to the document's start.
        private func restore(_ anchor: DiffScrollAnchor?) {
            guard let anchor, let document, let geometry,
                  let fileIndex = document.fileIndex(withID: anchor.fileID),
                  let top = geometry.top(ofFileAt: fileIndex)
            else { return scroll(toViewY: 0) }
            scroll(toContainerY: top + anchor.offsetInFile)
        }

        /// `DiffFragmentGeometry` speaks text-container coordinates and the clip
        /// view speaks the text view's, which holds the first file's reserved band
        /// above its container. `textContainerOrigin` rather than
        /// `textContainerInset`, because it also folds in any centering AppKit
        /// applies when the container is narrower than the view.
        private func scroll(toContainerY containerY: CGFloat) {
            scroll(toViewY: containerY + textView.textContainerOrigin.y)
        }

        /// Clamped by the clip view rather than by arithmetic here: a TextKit 2
        /// document's height is an estimate until it is laid out, so the clip view
        /// is the only thing that knows what it can actually show.
        private func scroll(toViewY viewY: CGFloat) {
            let clipView = self.clipView
            let target = NSRect(
                x: clipView.bounds.origin.x, y: viewY,
                width: clipView.bounds.width, height: clipView.bounds.height)
            clipView.scroll(to: clipView.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Repositions the header bars for the viewport's current top edge.
        ///
        /// The bounds-change notification this hangs off fires several times per
        /// frame under momentum scrolling, so the viewport is resolved once here and
        /// handed over whole — `DiffFragmentGeometry`'s point probe costs O(scroll
        /// offset), which is not a thing to pay per bar. The clip view's height is
        /// the authority on how much text is on screen, so the overlay is told
        /// rather than left to measure its own frame.
        private func updateStickyHeader() {
            stickyHeader.update(
                geometry: geometry, visibleTop: visibleTopInContainer,
                visibleHeight: clipView.bounds.height)
        }

        /// The viewport's top edge in text-container coordinates.
        private var visibleTopInContainer: CGFloat {
            clipView.bounds.origin.y - textView.textContainerOrigin.y
        }

        /// The viewport in text-container coordinates. The `x` extent is nominal —
        /// nothing here reads it — because the clip view's own `bounds.origin.x` is
        /// offset by the visible ruler and the text container is not.
        private var visibleRectInContainer: CGRect {
            CGRect(x: 0, y: visibleTopInContainer,
                   width: clipView.bounds.width, height: clipView.bounds.height)
        }
    }
}

/// Holds the scroll view with the pinned-header overlay above it.
///
/// A container with hand-computed frames rather than Auto Layout against the clip
/// view: `NSScrollView` positions its clip view and its rulers itself, in
/// `tile()`, so constraints onto them would fight that arrangement every time the
/// gutter's thickness changes — and the overlay's whole contract is to constrain
/// nothing.
final class DiffSurfaceContainerView: NSView {
    /// Called once the viewport has been re-tiled, for the owner to re-resolve
    /// whatever it derived from the viewport's previous size.
    ///
    /// The pinned bars are such a thing, and a document can arrive before this
    /// view has ever been sized — SwiftUI pushes it in `updateNSView`, which runs
    /// before the frame it hands down. Without this the bars would stay resolved
    /// against a zero-height viewport until the reader's first scroll.
    var viewportDidChange: (@MainActor () -> Void)?

    private let scrollView: NSScrollView
    private let stickyHeader: DiffStickyHeader

    init(scrollView: NSScrollView, stickyHeader: DiffStickyHeader) {
        self.scrollView = scrollView
        self.stickyHeader = stickyHeader
        super.init(frame: .zero)
        #if DEBUG
        LiveObjectCensus.track(self)
        #endif
        addSubview(scrollView)
        // Added last, so it draws over the text without taking part in its layout.
        addSubview(stickyHeader)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-down coordinates, matching the overlay's own: `y = 0` is the viewport's
    /// top edge, which is where the pinned bar sits.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // Tiled before its viewport is read, so the bar is placed against the clip
        // view's *current* frame rather than one layout pass behind it.
        scrollView.tile()
        // The clip view, not this view: under the legacy scroller style the scroll
        // bar takes a strip of its own out of the clip view's width, and a bar drawn
        // across it would sit permanently on top of the scroll bar. The gutter needs
        // no such allowance — the ruler overlays the clip view rather than narrowing
        // it — and the bar does run over the gutter, as it did when it was a section
        // header.
        let viewport = convert(scrollView.contentView.frame, from: scrollView)
        // The whole viewport, because a bar is drawn in every band the reader can
        // see: one rides up inside its own band while the current file's rests at
        // the top edge. Covering the viewport is safe precisely because the overlay
        // is inert — it hit-tests through to the text and constrains no layout.
        stickyHeader.frame = viewport
        viewportDidChange?()
    }
}
