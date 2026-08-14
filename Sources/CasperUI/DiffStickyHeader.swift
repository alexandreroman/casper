import AppKit

/// The diff's pinned file header, drawn over the top of the viewport.
///
/// An overlay rather than a view inside the text, and that is the whole point: it
/// *reads* `DiffFragmentGeometry` and feeds nothing back into text layout, which
/// is the class of bug this renderer exists to remove. The space it draws into is
/// reserved in the text flow as paragraph spacing
/// (`DiffTextAssembly.headerBandHeight`), so the bar covers a blank band holding
/// no characters at all — which is what keeps selection and copy free of stray
/// empty lines.
///
/// It reproduces `pinnedViews: [.sectionHeaders]` exactly. Every band the
/// viewport shows carries its file's bar, drawn at the band's own position, so a
/// file's name rides up the viewport inside its band the way an in-flow section
/// header does. The file owning the top edge holds its bar there instead, and the
/// band coming up under it pushes that bar out — which is the same statement as
/// the general one, since the pinned bar is only ever displaced by however much
/// the incoming band overlaps it.
final class DiffStickyHeader: NSView {
    /// One bar to draw: which file it describes, and its top edge in this view's
    /// own coordinates. Negative mid-push, when the outgoing bar is on its way out
    /// past the top edge.
    struct Bar: Equatable {
        let fileIndex: Int
        let y: CGFloat
    }

    /// The document the bars describe. Swapped together with the text storage —
    /// a stale document here would label a file with its predecessor's name.
    var document: DiffDocument? {
        didSet {
            // The indices in `bars` point into the *previous* document's files, so
            // they are dropped rather than redrawn; the surface recomputes them
            // from the new geometry in the same breath.
            bars = []
            needsDisplay = true
        }
    }

    /// The bars as of the last `update(geometry:visibleTop:visibleHeight:)`,
    /// top-down.
    ///
    /// A cache, which makes what invalidates it part of the contract. Three things
    /// do, and all three are wired in `DiffTextSurface.Coordinator`:
    ///
    /// - the viewport's top edge moving, off the clip view's bounds-change
    ///   notification;
    /// - a document swap or a viewport resize, through
    ///   `resolveBarsOverTheViewport()`;
    /// - **TextKit's layout settling**, through the text view's `didLayout`. The
    ///   first two resolve the bars over whatever geometry TextKit holds at that
    ///   moment, and past the point its real layout has reached that geometry is
    ///   *estimated*; a layout pass replaces the estimates with real heights and
    ///   every fragment below moves. Without this trigger the bars keep their
    ///   estimate-derived `y` until the reader's next scroll — bars stranded in the
    ///   middle of a file's code, reserved bands left blank.
    ///
    /// Every other piece of diff chrome — the row tints in `DiffTextView`, the
    /// stripe and numbers in `DiffGutterRuler` — reads `DiffFragmentGeometry` at
    /// *draw* time and so needs no such list.
    private(set) var bars: [Bar] = []

    /// How many times `update(geometry:visibleTop:visibleHeight:)` has been
    /// reached.
    ///
    /// Here for `DiffTextSurfaceTests`, which pins that a burst of layout passes
    /// collapses into a single re-resolution: resolving costs an O(scroll offset)
    /// point probe, and the finished bars record nothing about how many times they
    /// were computed.
    private(set) var resolutionCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed so the bar composites cleanly over the scrolling text
        // underneath it, and clipped so the outgoing bar disappears at the
        // viewport's top edge instead of drawing outside the overlay.
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-down coordinates, so `y = 0` is the viewport's top edge — the origin
    /// the push arithmetic below is written in.
    override var isFlipped: Bool { true }

    /// Decoration only: every click, drag and selection belongs to the text view
    /// behind it, including inside the band the bar covers.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Recomputes the bars for a viewport `visibleHeight` tall whose top edge is at
    /// `visibleTop`, both in **text-container** coordinates (what
    /// `DiffFragmentGeometry` answers in).
    ///
    /// The height is passed in rather than read off `bounds`: the clip view is what
    /// knows how much text is on screen, and it knows it before this view's frame
    /// has caught up with a resize.
    ///
    /// Repaints only when a bar actually moved, since this runs several times per
    /// frame under momentum scrolling. That is also what keeps the settled-layout
    /// path from repainting for nothing: a layout pass that moved no band leaves
    /// the overlay alone, and the overlay is a sibling view whose `needsDisplay`
    /// cannot dirty the text view's layout back.
    func update(geometry: DiffFragmentGeometry?, visibleTop: CGFloat, visibleHeight: CGFloat) {
        resolutionCount += 1
        let updated = resolveBars(
            geometry: geometry, visibleTop: visibleTop, visibleHeight: visibleHeight)
        guard updated != bars else { return }
        bars = updated
        needsDisplay = true
    }

    /// One bar per reserved band the viewport shows, at the band's own `y`, plus the
    /// current file's bar held at the top edge.
    ///
    /// **One point probe, and no layout forced at any point.** `fileIndex(atY:)`
    /// costs O(scroll offset), so it is asked exactly once and the files below are
    /// walked from there with `warmTop(ofFileAt:)`, a location lookup that costs the
    /// same wherever it points. Nothing here may call the forcing
    /// `top(ofFileAt:)`: this runs from a scroll bounds-change notification, several
    /// times per frame under momentum scrolling, and one `ensureLayout` walk on that
    /// path — 11 ms deep into a 20 000-line document — puts back exactly the cost
    /// this renderer exists to remove.
    ///
    /// **A cold band ends the walk**, which is the right answer and not a
    /// concession. `fileIndex(atY:)` has already resolved the viewport's top edge,
    /// and the draw that follows this notification lays out the rest of what the
    /// viewport shows, so a band TextKit has no geometry for lies below everything
    /// on screen — the same conclusion the `visibleHeight` test reaches, arrived at
    /// from the layout instead of from the arithmetic. At worst a band that has just
    /// come into view gets its bar one notification late, which no reader can see:
    /// notifications fire several times per frame.
    private func resolveBars(
        geometry: DiffFragmentGeometry?, visibleTop: CGFloat, visibleHeight: CGFloat
    ) -> [Bar] {
        guard let document, let geometry, let current = geometry.fileIndex(atY: visibleTop) else { return [] }

        var bands: [Bar] = []
        var fileIndex = current + 1
        while document.files.indices.contains(fileIndex), let top = geometry.warmTop(ofFileAt: fileIndex) {
            let y = top - visibleTop
            // Bands come in document order, so the first one starting past the bottom
            // edge means none of the files after it can be on screen either.
            guard y < visibleHeight else { break }
            bands.append(Bar(fileIndex: fileIndex, y: y))
            fileIndex += 1
        }

        // The current file's bar rests at the top edge and gives way to the band
        // coming up under it, by exactly as much as that band overlaps it. That
        // displacement *is* the push: it is negative only while the overlap lasts,
        // and the incoming bar is already in `bands`, drawn in its own band.
        let band = DiffTextAssembly.headerBandHeight
        var pinnedY: CGFloat = 0
        if let incoming = bands.first, incoming.y < band {
            pinnedY = incoming.y - band
        }
        return [Bar(fileIndex: current, y: pinnedY)] + bands
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let document else { return }
        for bar in bars where document.files.indices.contains(bar.fileIndex) {
            let frame = NSRect(x: bounds.minX, y: bar.y, width: bounds.width,
                               height: DiffTextAssembly.headerBandHeight)
            guard frame.intersects(dirtyRect) else { continue }
            draw(document.files[bar.fileIndex], in: frame)
        }
    }

    /// Draws one bar: path and status on the left, `+N` / `−N` pushed to the right,
    /// an opaque background, and a hairline along the bottom edge.
    ///
    /// Same content, faces and spacing as the row-based renderer's header, and the
    /// hairline is drawn *inside* the bar rather than under it so a bar occupies
    /// exactly the band the text flow reserved for it.
    private func draw(_ file: DiffDocument.FileSpan, in frame: NSRect) {
        // Two fills, as the row-based renderer had them: the window background so
        // the code cannot be read through the bar, and the translucent gray that
        // sets it apart from the code column.
        NSColor.windowBackgroundColor.setFill()
        frame.fill()
        Self.barTint.setFill()
        frame.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: frame.minX, y: frame.maxY - Self.hairlineHeight,
               width: frame.width, height: Self.hairlineHeight).fill()

        let content = NSRect(
            x: frame.minX + Self.horizontalPadding, y: frame.minY,
            width: max(frame.width - 2 * Self.horizontalPadding, 0),
            height: frame.height - Self.hairlineHeight)

        // Placed right to left, because the counts and the status are what they
        // measure and the title takes whatever is left — the flexible frame the
        // row-based renderer gave it.
        var trailing = content.maxX
        for piece in [deletions(file), insertions(file), status(file)] {
            let size = piece.size()
            piece.draw(in: NSRect(x: trailing - size.width, y: centeredY(of: size, in: content),
                                  width: size.width, height: size.height))
            trailing -= size.width + Self.itemSpacing
        }

        let title = title(file)
        let size = title.size()
        title.draw(in: NSRect(x: content.minX, y: centeredY(of: size, in: content),
                              width: max(trailing - content.minX, 0), height: size.height))
    }

    /// Centers a piece vertically in the bar, matching the row-based renderer's
    /// `HStack` — whose default center alignment was itself deliberate, a baseline
    /// guide there having been one suspect in the layout hang.
    private func centeredY(of size: NSSize, in content: NSRect) -> CGFloat {
        content.minY + (content.height - size.height) / 2
    }

    private func title(_ file: DiffDocument.FileSpan) -> NSAttributedString {
        NSAttributedString(string: file.title, attributes: Self.titleAttributes)
    }

    private func status(_ file: DiffDocument.FileSpan) -> NSAttributedString {
        NSAttributedString(string: file.status, attributes: Self.statusAttributes)
    }

    private func insertions(_ file: DiffDocument.FileSpan) -> NSAttributedString {
        NSAttributedString(string: "+\(file.insertions)", attributes: Self.insertionCountAttributes)
    }

    private func deletions(_ file: DiffDocument.FileSpan) -> NSAttributedString {
        // U+2212 MINUS SIGN, not a hyphen: it lines up with the `+` above it.
        NSAttributedString(string: "\u{2212}\(file.deletions)", attributes: Self.deletionCountAttributes)
    }

    private static let horizontalPadding: CGFloat = 8
    private static let itemSpacing: CGFloat = 8
    private static let hairlineHeight: CGFloat = 1

    /// `Color.secondary.opacity(0.12)` over the window background, as the
    /// row-based renderer stacked them.
    private static let barTint = NSColor.secondaryLabelColor.withAlphaComponent(0.12)

    /// Bold monospaced at the system body size, truncating in the middle: a path
    /// too long for the bar keeps both the repository-relative head and the file
    /// name, which is what makes a truncated path still identifiable.
    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .bold),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: middleTruncating,
    ]

    /// The status word, in the same 10 pt chrome size as the hunk headers.
    private static let statusAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: DiffTextAssembly.chromeFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private static let insertionCountAttributes = countAttributes(NSColor(DiffLineStyle.insertionTint))
    private static let deletionCountAttributes = countAttributes(NSColor(DiffLineStyle.deletionTint))

    /// Monospaced digits so `+N` and `−N` keep their width as the counts change,
    /// bold at the callout size — the row-based renderer's
    /// `.callout.monospacedDigit().bold()`.
    private static func countAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: color,
        ]
    }

    /// A title never wraps: the bar is one line tall, and a second line would draw
    /// over the file's first row of code.
    private static let middleTruncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style.copy() as! NSParagraphStyle
    }()
}
