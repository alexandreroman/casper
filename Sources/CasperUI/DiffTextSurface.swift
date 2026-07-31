import AppKit
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

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        controller.coordinator = coordinator
        return coordinator
    }

    func makeNSView(context: Context) -> DiffSurfaceContainerView {
        context.coordinator.containerView
    }

    func updateNSView(_ containerView: DiffSurfaceContainerView, context: Context) {
        // Nothing to push: the document, the scroll position and the highlights all
        // arrive through the controller. Re-linking is all this does, so a
        // `DiffSurfaceView` handed a fresh controller still reaches its surface.
        controller.coordinator = context.coordinator
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
                .setAttributedString(DiffTextAssembly.makeTextStorage(for: document))
            textView.document = document
            // Reflows the column's width itself, from its own setter.
            gutter.document = document
            stickyHeader.document = document
            scrollView.tile()

            restore(anchor)
            // The overlay only ever reads geometry TextKit already holds — its own
            // path may force none — and no draw has happened since the storage was
            // swapped, so the viewport is laid out here, once per refresh, for the
            // overlay to find the bands it shows.
            geometry?.ensureLayout(in: visibleRectInContainer)
            updateStickyHeader()
        }

        /// Paints one file's syntax colors into the live text storage.
        ///
        /// Unknown file IDs are ignored rather than reported: highlighting runs
        /// concurrently with refreshes, so a file finishing just after it left the
        /// diff is ordinary.
        func applyHighlight(_ highlight: DiffFileHighlight, forFileID fileID: String) {
            guard let document, let fileIndex = document.fileIndex(withID: fileID),
                  let storage = textView.textContentStorage?.textStorage
            else { return }
            DiffTextAssembly.applyHighlight(
                highlight, forFileAt: fileIndex, in: storage, document: document)
        }

        /// Scrolls the file's header band to the viewport's top edge.
        ///
        /// The target is usually far below what TextKit has laid out, which
        /// `ensureLayout(throughFileAt:)` settles outright — where the row-based
        /// renderer deferred a run-loop turn and hoped the row existed by then.
        func scroll(toFileID fileID: String) {
            guard let document, let geometry, let fileIndex = document.fileIndex(withID: fileID)
            else { return }
            geometry.ensureLayout(throughFileAt: fileIndex)
            guard let top = geometry.top(ofFileAt: fileIndex) else { return }
            scroll(toContainerY: top)
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

        private func restore(_ anchor: DiffScrollAnchor?) {
            guard let anchor, let document, let geometry,
                  let fileIndex = document.fileIndex(withID: anchor.fileID)
            else {
                scroll(toViewY: 0)
                return
            }
            geometry.ensureLayout(throughFileAt: fileIndex)
            guard let top = geometry.top(ofFileAt: fileIndex) else {
                scroll(toViewY: 0)
                return
            }
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
    private let scrollView: NSScrollView
    private let stickyHeader: DiffStickyHeader

    init(scrollView: NSScrollView, stickyHeader: DiffStickyHeader) {
        self.scrollView = scrollView
        self.stickyHeader = stickyHeader
        super.init(frame: .zero)
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
    }
}
