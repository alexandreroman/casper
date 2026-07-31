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

    /// Narrows every selection so its highlight stops short of each line's
    /// `+`/`-`/space cue.
    ///
    /// The cue is rendering rather than text (see
    /// `DiffDocument.rangesExcludingCues(in:)`), and the reader should be able to
    /// see that: a band running through the cue column says the cue is part of
    /// what they grabbed. So one selection becomes several — AppKit's own
    /// discontiguous selection, the same mechanism ⌘-drag uses — one per line, each
    /// starting at the code.
    ///
    /// This is the single funnel every selection change goes through: mouse drag,
    /// shift-click, double- and triple-click, ⌘A, and the coordinator's own calls.
    /// Which is why the two pass-throughs below matter more than the carving:
    ///
    /// - **A caret is left alone.** Every plain click arrives here as a zero-length
    ///   range, and carving one yields nothing — the reader would be unable to put
    ///   the caret down at all.
    /// - **A selection that is nothing but cues collapses to a caret** at the code's
    ///   start, rather than to no selection whatsoever. `NSTextView` requires at
    ///   least one range and double-clicking a `+` — its own punctuation run —
    ///   produces exactly this case.
    ///
    /// Idempotent, because the carving is: AppKit hands back the ranges it was
    /// given on the next change, and re-carving them must not shift them further.
    ///
    /// No storage/document length check here, unlike the pasteboard path below,
    /// and deliberately so: every carved piece is a *subrange* of a range AppKit
    /// derived from the storage itself, so a stale document can only put a
    /// boundary in an odd place, never out of bounds. The check would cost an
    /// `NSString` bridge of the whole diff text on every mouse-drag event to buy
    /// nothing.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        guard let document else {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        let carved: [NSRange] = ranges.map(\.rangeValue).flatMap { range -> [NSRange] in
            guard range.length > 0 else { return [range] }
            let pieces = document.rangesExcludingCues(in: range)
            guard pieces.isEmpty else { return pieces }
            return [NSRange(location: NSMaxRange(range), length: 0)]
        }
        super.setSelectedRanges(
            carved.map { NSValue(range: $0) }, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// Plain text only, so the cue-stripping below is the *whole* truth about
    /// what a copy carries.
    ///
    /// `NSTextView` would also offer RTF here, and a paste target that prefers it
    /// — Notes, Pages, a mail composer — would then get the representation that
    /// still has the `+`/`-` in it. Losing the syntax colors on such a paste is a
    /// fair trade: a diff is copied to be pasted as code.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Writes the selection with each line's `+`/`-`/space cue removed.
    ///
    /// `setSelectedRanges` has already carved the cues out of what the reader can
    /// select, so on a live view this pass finds nothing left to carve. It stays
    /// because the pasteboard is where the guarantee actually has to hold: a
    /// selection set before the document arrived, or by some future caller that
    /// bypasses the funnel, must still copy as code.
    ///
    /// The document and the storage can only disagree if they have drifted apart,
    /// and the length check refuses to carve by another document's offsets when
    /// they have: a verbatim copy is wrong in one small, bounded way, one sliced
    /// by stale offsets is wrong in an arbitrary one. The selection is still
    /// copied either way — a copy that silently yields nothing is worse than one
    /// that yields a patch.
    ///
    /// `selectedRanges`, not `selectedRange`: a discontiguous (⌘-drag) selection
    /// has several, and they are concatenated the way `NSTextView` concatenates
    /// them.
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let storage = textContentStorage?.textStorage else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        let selection = selectedRanges.map(\.rangeValue)
        let ranges: [NSRange] =
            if let document, storage.length == (document.text as NSString).length {
                selection.flatMap { document.rangesExcludingCues(in: $0) }
            } else {
                selection
            }

        let text = storage.string as NSString
        // Written even when empty — a selection covering nothing but cues copies
        // nothing, and leaving the previous clipboard contents in place would let
        // the reader paste something they never selected.
        pasteboard.setString(ranges.map { text.substring(with: $0) }.joined(), forType: .string)
        return true
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
