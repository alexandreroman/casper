import AppKit
import CasperGit

/// The diff's code column: a text view that paints a full-width tint band behind
/// every added and deleted row.
///
/// The tint is drawn here rather than set as a `.backgroundColor` text attribute
/// because an attribute only colors the glyphs' own extent — it would stop where
/// a line's text stops and leave the rest of the row untinted, where the
/// row-based renderer's `.background()` modifier covered the whole row. Same
/// reason the fill spans the view's width and not the fragment's: a row's
/// typographic width varies with its text, and `lineFragmentPadding` means it
/// does not even start at zero.
///
/// Every row's position comes from `DiffFragmentGeometry`, the one reader of
/// TextKit layout, so a tint cannot land on a different row than the stripe the
/// gutter draws beside it.
final class DiffTextView: NSTextView {
    /// The document the text storage was assembled from — the tints are drawn
    /// from its spans, so it has to be swapped in the same breath as the storage.
    /// A stale document here would tint rows by the *previous* diff's kinds.
    var document: DiffDocument? {
        didSet { needsDisplay = true }
    }

    /// Called after every layout pass, for whoever holds geometry this view's
    /// layout has just invalidated.
    ///
    /// TextKit answers with *estimated* heights for content it has not laid out
    /// yet, and a layout pass replaces those estimates with real ones — which
    /// moves every fragment below whatever moved. Chrome that reads
    /// `DiffFragmentGeometry` at draw time follows on its own; the pinned header,
    /// which caches the positions it resolved, needs telling.
    var didLayout: (@MainActor () -> Void)?

    /// `super.layout()` is where TextKit 2 lays the viewport out, so the callback
    /// runs after it, with the settled geometry in place.
    override func layout() {
        super.layout()
        didLayout?()
    }

    /// Fills the row tints, over the view's background and under everything else.
    ///
    /// The selection highlight is drawn later in the draw cycle, so a selection
    /// stays visible on top of a tinted row. Nil-tolerant on both counts: a view
    /// with no document yet, or one that has been migrated to the TextKit 1 stack
    /// and has no `textLayoutManager`, has nothing to place a tint by and draws
    /// none rather than guessing.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)

        guard let document, let layoutManager = textLayoutManager else { return }
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)
        // `DiffFragmentGeometry` speaks text-container coordinates and this rect
        // is in view coordinates. `textContainerOrigin` is where the container
        // actually sits — it folds `textContainerInset` together with any
        // centering AppKit applies when the container is narrower than the view,
        // which the inset alone does not report.
        //
        // Both directions matter and they fail differently. Get the query wrong
        // and rows are looked up for the wrong strip of the document: while
        // scrolling, `dirtyRect` is only the newly exposed strip, so the top of
        // every repainted strip would come back untinted and heal only on a full
        // redraw. Get the fill wrong and every tint is offset by a band height.
        let containerY = textContainerOrigin.y

        for row in geometry.fragments(in: dirtyRect.offsetBy(dx: 0, dy: -containerY)) {
            guard let kind = document.lines[row.lineIndex].diffKind,
                  let tint = Self.rowTint(for: kind)
            else { continue }
            tint.setFill()
            // Rows straddling `dirtyRect`'s edges come back at full height on
            // purpose — a half-height tint would be a visible seam — and the
            // graphics context clips whatever falls outside.
            NSRect(x: bounds.minX, y: row.rect.minY + containerY, width: bounds.width, height: row.rect.height)
                .fill()
        }
    }

    /// The tint behind one diff row, or `nil` when there is nothing to paint.
    ///
    /// Shared with `DiffGutterRuler`, which fills the same band across its own
    /// width so the tint runs unbroken under the gutter: one function, so the two
    /// halves of a row cannot come out different colors. `nil` for a context row,
    /// whose `DiffLineStyle.background(for:)` is `Color.clear` — as it is for the
    /// hunk headers and notes that have no diff kind at all.
    static func rowTint(for kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: additionTint
        case .deletion: deletionTint
        case .context: nil
        }
    }

    /// `NSColor(_:)` allocates a dynamic catalog color, and this runs once per
    /// visible row per frame, so the two tints are converted once instead.
    private static let additionTint = NSColor(DiffLineStyle.background(for: .addition))
    private static let deletionTint = NSColor(DiffLineStyle.background(for: .deletion))
}
