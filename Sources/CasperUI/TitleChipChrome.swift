import SwiftUI

/// The metrics every title-bar chip shares.
///
/// A named constant rather than a literal per call site so the layout tests can
/// assert the chips still lay out as one row against the very number the chrome
/// applies.
enum TitleCapsuleMetrics {
    static let height: CGFloat = 36

    /// The capsule's interior horizontal inset.
    static let horizontalInset: CGFloat = 10

    /// The slot every glyph-only chip reserves for its glyph.
    ///
    /// Fixed on purpose: SF Symbols carry different intrinsic widths, so chips sized
    /// to their content come out uneven — measured, the five symbols that sit in it
    /// are `arrow.triangle.merge` and `plusminus` at 12 pt, `ellipsis` at 14, and
    /// `trash` and `globe` at 15. A row of glyph-only chips is a row of identical
    /// pills; one wider than its neighbours reads as a different KIND of control
    /// rather than as the same control shortened. The slot makes them identical by
    /// construction rather than by two symbols happening to agree.
    ///
    /// Sized from the `⋯` chip, which is the reference dimension for the set, then
    /// widened to clear the widest glyph that has to sit in it — so every chip
    /// widened together and they stayed identical. Roomier than that widest glyph on
    /// purpose: a slightly generous chip looks fine, an overflowing one does not.
    static let glyphSlotWidth: CGFloat = 18

    /// The width every glyph-only chip lays out to, `⋯` included.
    static let glyphChipWidth: CGFloat = glyphSlotWidth + 2 * horizontalInset
}

/// How a title-bar chip answers the pointer: the capsule's fill at rest, under the
/// pointer and held down, and what a held chip does on top of that.
///
/// The fills are one neutral step each, the same in both palettes (no accent, see
/// the `title-bar-chip-chrome` note), and each state reads stronger than the one
/// before it — pressed has to read past hover, because the pointer is always over
/// a chip while it is held, so a press that only matched hover would show nothing.
/// Named rather than spelled at the call site so `TitleChipFeedbackTests` can pin
/// that ordering against the very numbers the chrome applies.
enum TitleChipFeedback {
    static let restingFillOpacity = 0.15
    static let hoveredFillOpacity = 0.28
    static let pressedFillOpacity = 0.40

    /// How far a held chip shrinks around its centre. A render-only effect, so the
    /// row never reflows under a click; kept slight because the whole pill — text,
    /// glyph and capsule together — moves, which reads as a press long before it
    /// reads as a resize.
    static let pressedScale: CGFloat = 0.95

    /// The info button's bare glyph has no capsule to darken, so its press is
    /// carried by the glyph alone. It shrinks further than a chip because it is far
    /// smaller: 5% of a 15 pt glyph is under a point and would not register.
    static let pressedGlyphScale: CGFloat = 0.85
    static let pressedGlyphOpacity = 0.6

    /// What `.plain` does to a disabled label, measured — so swapping it for
    /// `TitleChipButtonStyle` leaves a disabled Run action looking exactly as it did.
    static let disabledOpacity = 0.5

    /// The same short ease-out as the hover highlight, in both directions: a click
    /// lasts about a tenth of a second, so the press has to land and release within
    /// that window to be seen at all.
    static var animation: Animation { .easeOut(duration: 0.12) }

    /// The capsule's fill opacity. Pressed wins over hovered, which wins over
    /// resting.
    static func fillOpacity(hovered: Bool, pressed: Bool) -> Double {
        if pressed {
            return pressedFillOpacity
        }
        if hovered {
            return hoveredFillOpacity
        }
        return restingFillOpacity
    }
}

/// The button style every title-bar chip uses in place of `.plain`: the label
/// drawn untouched, with its press reported to the capsule chrome.
///
/// `.plain` exposes no press to the chrome, so under it a held chip looks exactly
/// like a hovered one. The chrome is what answers the press, but it sits on either
/// side of the button depending on the chip — INSIDE the label for single-button
/// chips (the diff badge, Merge, `⋯`), AROUND the button for the shells (Run /
/// Editor, the inspector selector), see the `title-capsule-hit-area` note — so the
/// style publishes the press both ways: down through `\.titleChipPressed` and up
/// through `TitleChipPressedKey`. The info button, which has no chrome, reads the
/// environment side directly through `titleChipGlyphPressEffect()`.
///
/// Otherwise it behaves like `.plain`: no padding, no background, and a hit area
/// that is exactly the label's shape, which every chip's geometry relies on.
struct TitleChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TitleChipButtonBody(configuration: configuration)
    }
}

/// `TitleChipButtonStyle`'s body, as a view of its own so it can read `isEnabled`
/// for the disabled look.
private struct TitleChipButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .environment(\.titleChipPressed, configuration.isPressed)
            .preference(key: TitleChipPressedKey.self, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : TitleChipFeedback.disabledOpacity)
    }
}

extension EnvironmentValues {
    /// Whether the `TitleChipButtonStyle` button this view sits inside is held
    /// down. Read by chrome drawn inside a button's label, and by the info button's
    /// glyph.
    @Entry var titleChipPressed = false
}

/// Carries `isPressed` up from a `TitleChipButtonStyle` button to the capsule shell
/// wrapping it. OR-reduced, so a shell holding two buttons — the inspector
/// selector's segments — reads as pressed while either one is.
private struct TitleChipPressedKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The capsule chrome itself — fixed height, fill, hairline border, hit shape —
/// plus the hover highlight that makes a chip read as clickable, and the pressed
/// look that confirms the click: the fill steps past hover and the
/// whole pill shrinks slightly (fill alone under Reduce Motion).
///
/// It lives in a `ViewModifier` (rather than as `.onHover` on each call site) for
/// the `@State` it needs, and because sitting on the shell makes hover cover the
/// WHOLE pill, including the nested borderless `Menu` chevron of the split
/// buttons — a per-control `.onHover` would flicker as the pointer crosses them.
private struct TitleCapsuleChrome: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The press of the button whose label this chrome is drawn in.
    @Environment(\.titleChipPressed) private var enclosingButtonPressed
    @State private var hovering = false
    /// The press of a button this chrome wraps, reported up from inside it.
    @State private var wrappedButtonPressed = false

    private var pressed: Bool { enclosingButtonPressed || wrappedButtonPressed }

    /// Native toolbar controls dim when the window stops being key/main, so the
    /// chips dim with them. Fading the whole shell keeps the glyphs,
    /// the +N/−N tints and the capsule in step, and opacity alone can never shift
    /// the layout.
    private var shellOpacity: Double { controlActiveState == .inactive ? 0.5 : 1 }

    private var fill: Color {
        Color.secondary.opacity(TitleChipFeedback.fillOpacity(hovered: hovering, pressed: pressed))
    }

    private var scale: CGFloat {
        pressed && !reduceMotion ? TitleChipFeedback.pressedScale : 1
    }

    func body(content: Content) -> some View {
        content
            .frame(height: TitleCapsuleMetrics.height)
            // A scoped animation rather than `.animation(_:value:)`: only the
            // chrome's own fill, border and scale animate here, never the label
            // inside it. Releasing a press is also when the click's action lands,
            // and a value-keyed animation would hijack whatever that action
            // changes in the label — the inspector indicator's slide, for one.
            .animation(TitleChipFeedback.animation) { chrome in
                chrome
                    .background(fill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .scaleEffect(scale)
            }
            // Past the scale, so the hit shape stays the full-size capsule: a chip
            // shrinking under a press held near its rim must not slip out from
            // under the pointer and cancel that press.
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onPreferenceChange(TitleChipPressedKey.self) { wrappedButtonPressed = $0 }
            .opacity(shellOpacity)
            .animation(TitleChipFeedback.animation, value: controlActiveState)
    }
}

extension View {
    /// The one shared title-bar capsule chrome. Every title-bar chip uses this so
    /// they render strictly identically. Explicit fill + hairline border (not
    /// Liquid Glass) because glass renders nearly invisible on chips that embed a
    /// nested borderless `Menu` (Run / Editor), so this is the only treatment that
    /// works for every chip.
    ///
    /// Every chip is a button, so the chrome lights up on hover like a native
    /// toolbar button and darkens while pressed; see `TitleCapsuleChrome`. The
    /// press needs the chip's button to use `TitleChipButtonStyle`.
    func titleCapsule() -> some View {
        self
            .padding(.horizontal, TitleCapsuleMetrics.horizontalInset)
            .titleCapsuleShell()
    }

    /// Reserves the shared glyph slot, so every glyph-only chip is the same width
    /// whatever symbol it draws.
    ///
    /// Goes INSIDE the capsule's padding (see the `fixed-frame-swallows-inner-padding`
    /// note): the insets still widen the pill around it, and the whole pill stays
    /// clickable rather than just the glyph.
    func glyphSlot() -> some View {
        frame(width: TitleCapsuleMetrics.glyphSlotWidth)
    }

    /// The capsule chrome WITHOUT the interior horizontal padding. Split out from
    /// `titleCapsule` so a split-button (Run / Editor) can wrap the whole HStack in
    /// the visible pill while its inner controls carry the padding themselves —
    /// keeping that padding inside their clickable label instead of as dead
    /// decoration around the button (see the `title-capsule-hit-area` memory
    /// note). A wrapped button's press still reaches the shell, through
    /// `TitleChipButtonStyle`.
    func titleCapsuleShell() -> some View {
        modifier(TitleCapsuleChrome())
    }
}

extension View {
    /// The press feedback for a title-bar control with no capsule to darken — the
    /// info button's bare glyph: it shrinks and dims while the
    /// `TitleChipButtonStyle` button holding it is pressed (dims only under Reduce
    /// Motion).
    ///
    /// Apply it to the glyph itself, inside any frame or padding: the scale is a
    /// render-only effect, and on the glyph alone it leaves the button's bounds —
    /// and anything anchored to them, like the info button's popover — untouched.
    func titleChipGlyphPressEffect() -> some View {
        modifier(TitleChipGlyphPressEffect())
    }
}

private struct TitleChipGlyphPressEffect: ViewModifier {
    @Environment(\.titleChipPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        pressed && !reduceMotion ? TitleChipFeedback.pressedGlyphScale : 1
    }

    func body(content: Content) -> some View {
        // Scoped for the same reason as the capsule chrome's: the glyph's own
        // changes (its unread fill, its pulse) keep their own animations.
        content.animation(TitleChipFeedback.animation) { glyph in
            glyph
                .scaleEffect(scale)
                .opacity(pressed ? TitleChipFeedback.pressedGlyphOpacity : 1)
        }
    }
}
