import AppKit

/// The one place that reads TextKit 2 layout geometry, and turns it back into
/// diff-line terms.
///
/// Three views draw per-line chrome — the row tints in `DiffTextView`, the
/// stripe and numbers in `DiffGutterRuler`, the pinned bar in
/// `DiffStickyHeader` — and each of them needs the same answer: which diff line
/// does this piece of laid-out geometry belong to. They all ask here, so their
/// output cannot disagree about where a line is. That is the whole reason this
/// type exists, and why there is deliberately no second geometry backend: a
/// TextKit 1 fallback would be a duplicate answer to the same question, free to
/// drift from this one.
///
/// **Coordinate space.** Every rect and every `y` here is in the *text
/// container's* space, which is what `NSTextLayoutManager` reports. A text view
/// shifts that by its `textContainerInset`, so a caller holding view
/// coordinates (`drawBackground(in:)`, an `NSRulerView` rect, a clip view's
/// bounds) converts on the way in and on the way out. Doing the conversion here
/// is not an option: the layout manager does not know the inset — only the text
/// view does. Each member below repeats this where it matters, because the
/// members are what a caller reads while holding a view-space number.
///
/// `@MainActor` because live TextKit layout is main-thread-only, and because
/// `DiffTextAssembly`'s constants are.
@MainActor
struct DiffFragmentGeometry {
    /// One laid-out visual row: a single TextKit line fragment, resolved to the
    /// diff line it renders part of.
    struct Fragment {
        /// Index into `DiffDocument.lines`.
        let lineIndex: Int
        /// The row's typographic bounds, in text-container coordinates.
        ///
        /// Only the vertical extent describes the *row*. Horizontally this is
        /// where the glyphs are, which is not where a row's chrome goes:
        /// `minX` carries the text container's `lineFragmentPadding` (5 pt by
        /// default) and `width` is the row's typographic width, so it varies
        /// line by line with the text. A full-width row tint therefore ignores
        /// both and spans its own view instead.
        let rect: CGRect
        /// True for the first visual row of the line only. A wrapped line spans
        /// several rows but is one logical line, so the gutter prints its number
        /// once — on this row — instead of once per row.
        let isLineStart: Bool
    }

    private let layoutManager: NSTextLayoutManager
    private let document: DiffDocument

    init(layoutManager: NSTextLayoutManager, document: DiffDocument) {
        self.layoutManager = layoutManager
        self.document = document
    }

    /// The rows overlapping `rect`, in document order, in text-container
    /// coordinates.
    ///
    /// **Filtered by `rect`, not clipped to it.** A row straddling `rect.minY`
    /// or `rect.maxY` comes back at its full height, which is what a full-row
    /// tint wants — a half-height tint on the first visible row would be a
    /// visible seam. A caller that needs its geometry to stop at the rect's edge
    /// does that intersection itself.
    ///
    /// **The enumeration is bounded by `rect`**: it starts at the layout
    /// fragment covering `rect.minY` and stops as soon as one starts past
    /// `rect.maxY`, so TextKit lays out the rect's worth of rows and no more.
    /// That bound is load-bearing rather than an optimisation — this runs from
    /// `drawBackground(in:)` and from the ruler on every scroll notification, so
    /// the moment its cost becomes proportional to the document instead of to
    /// the visible rect, scrolling a 20 000-line diff starts laying out the
    /// whole thing on every frame. Measured on a cold 20 000-line document, a
    /// 300 pt rect leaves `usageBoundsForTextContainer.height` at 318 against
    /// 351 372 for the whole document; `testEnumerationLaysOutOnlyTheRequestedRect`
    /// pins it.
    ///
    /// **The entry probe carries no such bound.** `textLayoutFragment(for:)` on
    /// a *point* scans forward from the document start, so its cost tracks the
    /// scroll offset, not `rect`: over that same document, 0.005 ms at `y = 100`
    /// against 1.17 ms at the bottom (the location-based lookup `top(ofFileAt:)`
    /// uses is 0.004 ms wherever it points). One such probe per draw is
    /// affordable; a bound that is not there must not be built on.
    func fragments(in rect: CGRect) -> [Fragment] {
        guard rect.height > 0, let first = layoutFragment(atY: rect.minY) else { return [] }

        var fragments: [Fragment] = []
        _ = layoutManager.enumerateTextLayoutFragments(
            from: first.rangeInElement.location, options: [.ensuresLayout]
        ) { layoutFragment in
            let frame = layoutFragment.layoutFragmentFrame
            guard frame.minY < rect.maxY else { return false }

            // Defence, not a normal case: `DiffDocument`'s spans tile the whole
            // storage, so a fragment start offset that matches none of them means
            // this storage was assembled from a *different* `DiffDocument` than
            // the one held here — the same mismatch `DiffTextAssembly`'s
            // `applyHighlight` refuses on, and with the same reasoning. Chrome for
            // an arbitrary line is worse than no chrome.
            guard let lineIndex = lineIndex(of: layoutFragment) else { return true }

            for (position, lineFragment) in layoutFragment.textLineFragments.enumerated() {
                // TextKit hangs an extra, characterless line fragment off the
                // last paragraph — the caret position after the document's final
                // "\n". It renders no diff line, so letting it through would tint
                // and stripe one phantom row at the bottom of every diff. A
                // paragraph's first row is always real (it owns at least its
                // terminator), which is what makes the emptiness test safe.
                guard position == 0 || lineFragment.characterRange.length > 0 else { continue }

                // `typographicBounds` is relative to the layout fragment's own
                // origin; the frame puts it back into container coordinates.
                let rowRect = lineFragment.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                guard rowRect.maxY > rect.minY, rowRect.minY < rect.maxY else { continue }
                fragments.append(
                    Fragment(lineIndex: lineIndex, rect: rowRect, isLineStart: position == 0))
            }
            return true
        }
        return fragments
    }

    /// Lays out the rows `rect` shows and no more — it *is* `fragments(in:)`,
    /// under the same bound, with the rows thrown away.
    ///
    /// For the caller that needs the viewport laid out before reading it. The
    /// sticky header resolves its bands with `warmTop(ofFileAt:)` and takes a file
    /// with no geometry for one below the screen, which holds while scrolling
    /// because every draw lays out what it paints. Right after a document swap
    /// nothing has drawn yet, so the refresh path warms the viewport once instead
    /// of letting the overlay conclude the diff is one file long.
    func ensureLayout(in rect: CGRect) {
        _ = fragments(in: rect)
    }

    /// The `y` of the top of the blank band reserved for the file's sticky
    /// header, in **text-container** coordinates — so a caller holding a clip
    /// view's `bounds.origin.y` subtracts `textContainerInset.height` before
    /// comparing, and adds it back before scrolling.
    ///
    /// **Negative for the first file**, whose band is the text view's
    /// `textContainerInset` and therefore sits *above* the container's origin:
    /// its band top is `-DiffTextAssembly.headerBandHeight`. Every file is still
    /// measured by the same formula — see `bandTop(ofFirstParagraph:)`.
    ///
    /// `nil` for an out-of-range index, or for a file TextKit cannot produce a
    /// laid-out fragment for.
    ///
    /// Layout is *probed* first — through `warmTop(ofFileAt:)`, so the two share
    /// one probe — and only forced when the probe comes back cold. Forcing it
    /// unconditionally would cost an `ensureLayout(throughFileAt:)` walk, linear
    /// in how deep the file sits, for an answer the layout already holds: on a
    /// laid-out 20 000-line document, 0.010 ms for the probe against 11.0 ms for
    /// the walk to the last file. `testWarmFileTopCostsFarLessThanALayoutWalk`
    /// pins the gap, and `testFileTopIsTheSameColdAsWarm` pins that the shortcut
    /// answers the same.
    ///
    /// **This is the forcing variant, for one-shot jumps** — `scroll(toFileID:)`
    /// and anchor restoration, where the walk buys a real frame instead of an
    /// estimate and is paid once. Anything running per scroll notification asks
    /// `warmTop(ofFileAt:)` instead and treats a cold file as out of view.
    func top(ofFileAt fileIndex: Int) -> CGFloat? {
        if let warm = warmTop(ofFileAt: fileIndex) { return warm }
        ensureLayout(throughFileAt: fileIndex)
        return warmTop(ofFileAt: fileIndex)
    }

    /// The same band top as `top(ofFileAt:)`, but only for a file TextKit has
    /// already laid out the first paragraph of: `nil` for a cold one, with no
    /// `ensureLayout` fallback.
    ///
    /// The accessor for callers that may not force layout at all — the sticky
    /// header, which recomputes out of a scroll bounds-change notification
    /// several times per frame. A cold file there is not a failure to work
    /// around: layout runs from the top down, so a file without geometry is a
    /// file below everything TextKit has produced for the viewport.
    ///
    /// `nil` for an out-of-range index too, as `top(ofFileAt:)`.
    func warmTop(ofFileAt fileIndex: Int) -> CGFloat? {
        guard document.files.indices.contains(fileIndex) else { return nil }
        let offset = document.files[fileIndex].range.location
        guard let fragment = layoutFragment(atCharacterOffset: offset),
              fragment.state == .layoutAvailable
        else { return nil }
        return bandTop(ofFirstParagraph: fragment)
    }

    /// The file owning `y`, with ownership starting at the file's reserved band
    /// rather than at its first row: the band is where its header bar draws, so
    /// the sticky overlay has to consider the file current from there down.
    ///
    /// `y` is in **text-container** coordinates, so a caller holding a clip
    /// view's `bounds.origin.y` subtracts `textContainerInset.height` first.
    ///
    /// Deliberately does **not** call `top(ofFileAt:)`. This is the sticky
    /// header's hot path — a scroll bounds-change notification fires several
    /// times per frame under momentum scrolling — and `top` may force layout.
    /// The fragment already in hand answers the same question, because a band
    /// only ever sits above a file's *first* paragraph: reach any later
    /// paragraph of the file and `y` is provably at or below the band already.
    /// Measured near the bottom of a laid-out 20 000-line document, that is
    /// 1.95 ms against 12.0 ms for the same answer via `top(ofFileAt:)` — and
    /// with the whole sticky-header pair (this plus the next file's top), 1.09 ms
    /// against 23.7 ms per notification.
    func fileIndex(atY y: CGFloat) -> Int? {
        guard let fragment = layoutFragment(atY: y), let lineIndex = lineIndex(of: fragment)
        else { return nil }
        let candidate = document.lines[lineIndex].fileIndex

        // A later file's first layout fragment starts *above* its band, because
        // the inter-file gap is folded into the same `paragraphSpacingBefore`. So
        // the lookup claims the file a gap's height too early, and the boundary
        // has to be corrected back to the band's top — otherwise the sticky
        // overlay adopts the incoming file while the outgoing one is still
        // mid-push, and the incoming bar jumps by the gap's height. File 0 needs
        // no correction: it has no gap above it, and no predecessor to hand `y`
        // back to.
        guard candidate > 0, lineIndex == document.files[candidate].firstLineIndex,
              y < bandTop(ofFirstParagraph: fragment)
        else { return candidate }
        return candidate - 1
    }

    /// Forces layout as far as the file's first paragraph, which is what gives
    /// `top(ofFileAt:)` a real frame instead of an estimated one.
    ///
    /// Stopping at the first paragraph rather than at the end of the file is
    /// deliberate: every caller wants the file's top, so jumping to a 3000-line
    /// file need not pay for that file's body. It still costs everything *above*
    /// the file, though — TextKit lays out forward, so the range has to start at
    /// the document's origin. On a cold 20 000-line document, reaching the last
    /// file lays out 99.5% of its height; and even over content already laid out,
    /// the walk itself costs 11.0 ms. That is why `top(ofFileAt:)` probes before
    /// resorting to this, and why nothing on the per-scroll-notification path —
    /// `fileIndex(atY:)`, `warmTop(ofFileAt:)` — reaches it at all.
    func ensureLayout(throughFileAt fileIndex: Int) {
        guard document.files.indices.contains(fileIndex) else { return }
        // Safe by `DiffDocument`'s invariant that every file owns at least one
        // paragraph.
        let firstLine = document.lines[document.files[fileIndex].firstLineIndex]
        let start = layoutManager.documentRange.location
        // + 1 for the paragraph terminator, so the range covers the paragraph
        // whole and TextKit cannot stop just short of laying it out.
        let end = layoutManager.location(start, offsetBy: NSMaxRange(firstLine.range) + 1)
            ?? layoutManager.documentRange.endLocation
        guard let range = NSTextRange(location: start, end: end) else { return }
        layoutManager.ensureLayout(for: range)
    }

    /// The top of the blank band reserved ahead of the file whose **first**
    /// paragraph `fragment` lays out. One formula for both kinds of file, in one
    /// place, so the three members that answer in band tops — `top(ofFileAt:)`,
    /// `warmTop(ofFileAt:)` and `fileIndex(atY:)` — cannot drift apart.
    ///
    /// The two kinds reserve their band by different mechanisms, which is why
    /// the row offset appears in the arithmetic at all:
    ///
    /// - Files after the first reserve theirs *inside the text flow*, with
    ///   `paragraphSpacingBefore` on their first paragraph
    ///   (`DiffTextAssembly.laterFileStyle`). TextKit folds that spacing into the
    ///   layout fragment's frame and pushes the first row down by it, so for such
    ///   a paragraph `textLineFragments.first!.typographicBounds.minY` equals
    ///   `headerBandHeight + interFileGap` exactly — that relationship, not any
    ///   particular pixel value, is what this arithmetic rests on. Subtracting the
    ///   band from `frame.minY` alone would report a band top a whole band plus
    ///   gap too high.
    /// - The first file has no `paragraphSpacingBefore` — TextKit ignores it on
    ///   the document's very first paragraph — so that offset is 0 and the formula
    ///   reduces to `frame.minY - headerBandHeight`, i.e. `-headerBandHeight`. Its
    ///   band genuinely lives above the container, in the text view's
    ///   `textContainerInset`. Returning the container origin instead would hand
    ///   back the band's *bottom*, and the sticky bar would paint over the file's
    ///   first hunk header — the one-band-height error that made this an explicit
    ///   helper.
    private func bandTop(ofFirstParagraph fragment: NSTextLayoutFragment) -> CGFloat {
        let frame = fragment.layoutFragmentFrame
        let rowOffset = fragment.textLineFragments.first?.typographicBounds.minY ?? 0
        return frame.minY + rowOffset - DiffTextAssembly.headerBandHeight
    }

    /// The diff line the fragment renders. One `LineSpan` is exactly one TextKit
    /// paragraph (a `DiffDocument` invariant) and a layout fragment covers one
    /// paragraph, so the fragment's start offset identifies the line outright —
    /// no per-row character arithmetic needed.
    private func lineIndex(of layoutFragment: NSTextLayoutFragment) -> Int? {
        let offset = layoutManager.offset(
            from: layoutManager.documentRange.location, to: layoutFragment.rangeInElement.location)
        return document.lineIndex(atCharacterOffset: offset)
    }

    private func layoutFragment(atY y: CGFloat) -> NSTextLayoutFragment? {
        // Clamped: a caller can hand over a negative `y` — from a rubber-band
        // overscroll, or from the first file's band, which sits above the
        // container's origin — and there is no geometry up there to find.
        layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(y, 0)))
    }

    /// UTF-16 offsets throughout, matching `DiffDocument`'s `NSRange`s.
    private func layoutFragment(atCharacterOffset offset: Int) -> NSTextLayoutFragment? {
        guard let location = layoutManager.location(layoutManager.documentRange.location, offsetBy: offset)
        else { return nil }
        return layoutManager.textLayoutFragment(for: location)
    }
}
