import GhosttyKit
import Foundation

/// Owns a libghostty `ghostty_surface_t` and frees it on deinit (same ownership
/// pattern as `CasperGit.Repository`). Main-thread affine; not `Sendable`.
final class GhosttySurface {
    let surface: ghostty_surface_t

    /// Pins the runtime's `ghostty_app_t` alive for as long as this surface
    /// exists, since the surface belongs to that app and frees itself into it.
    private let runtime: GhosttyRuntime

    /// Create a surface hosted in `nsview`. `userdata` is handed back verbatim to
    /// libghostty's clipboard/close callbacks — pass the view pointer so those
    /// callbacks can recover the owning `GhosttySurfaceView`. Throws if the
    /// runtime has no app or libghostty returns null.
    init(
        runtime: GhosttyRuntime,
        configuration: GhosttySurfaceConfiguration,
        nsview: UnsafeMutableRawPointer,
        userdata: UnsafeMutableRawPointer?
    ) throws {
        guard let app = runtime.app else {
            throw GhosttyError(reason: "runtime has no app")
        }
        let created = configuration.withCValue(nsview: nsview, userdata: userdata) { c in
            ghostty_surface_new(app, &c)
        }
        guard let created else {
            throw GhosttyError(reason: "ghostty_surface_new returned null")
        }
        self.surface = created
        self.runtime = runtime

        // libghostty's own `initial_input` config field mojibakes non-ASCII text
        // (it expands each byte as a Latin-1 scalar), so inject the queued input
        // through the UTF-8 `ghostty_surface_text` path here, right after the child
        // is spawned — the tightest equivalent to where `initial_input` was applied.
        if let initial = configuration.initialInput, !initial.isEmpty {
            sendText(initial)
        }
    }

    deinit { ghostty_surface_free(surface) }

    /// Set the drawable size in *pixels* (backing-store units).
    func setSize(widthPixels: UInt32, heightPixels: UInt32) {
        ghostty_surface_set_size(surface, widthPixels, heightPixels)
    }

    func setContentScale(x: Double, y: Double) {
        ghostty_surface_set_content_scale(surface, x, y)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    /// Tell libghostty whether this surface is occluded (off-screen). When
    /// occluded, libghostty pauses the surface's render thread; clearing it
    /// resumes rendering. Balances `set_display_id`, which arms the render loop.
    func setOcclusion(_ occluded: Bool) {
        ghostty_surface_set_occlusion(surface, occluded)
    }

    /// Committed/IME text (from `NSTextInputClient.insertText`).
    func sendText(_ text: String) {
        // Pass the full UTF-8 byte length, not strlen: the withCString buffer
        // preserves embedded NULs, so text containing U+0000 is sent intact.
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    @discardableResult
    func sendKey(_ event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) {
        _ = ghostty_surface_mouse_button(surface, state, button, mods)
    }

    func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    func sendMouseScroll(
        deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t
    ) {
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }

    /// Whether the surface currently has an active text selection.
    func hasSelection() -> Bool { ghostty_surface_has_selection(surface) }

    /// Whether the terminal app is currently capturing the mouse (mouse reporting
    /// active). When true, right-clicks belong to the app, not an AppKit menu.
    func mouseCaptured() -> Bool { ghostty_surface_mouse_captured(surface) }

    /// Deliver clipboard text back to libghostty for a pending read (paste)
    /// request. `state` is the opaque token libghostty handed to the read
    /// callback; it must be passed back unchanged.
    func completeClipboardRequest(
        _ text: String, state: UnsafeMutableRawPointer?, confirmed: Bool
    ) {
        text.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    /// Trigger a libghostty keybinding action by name (e.g. `"copy_to_clipboard"`,
    /// `"paste_from_clipboard"`, `"select_all"`), bypassing key-event translation.
    /// Returns whether the action was recognized and performed.
    @discardableResult
    func bindingAction(_ name: String) -> Bool {
        name.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(name.utf8.count))
        }
    }

    /// Read the terminal's text: the visible viewport, or the full screen
    /// (including scrollback) when `scrollback` is true. Returns nil if
    /// libghostty declines to produce a selection.
    func readText(scrollback: Bool) -> String? {
        let tag = scrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var out = ghostty_text_s()
        // Register cleanup before the fallible read so a failed read still frees any
        // partially-allocated buffer (project pointer-lifecycle convention). Freeing a
        // zero-initialized ghostty_text_s (text == nil) is a no-op.
        defer { ghostty_surface_free_text(surface, &out) }
        guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
        guard let bytes = out.text else { return "" }
        return String(decoding: Data(bytes: bytes, count: Int(out.text_len)), as: UTF8.self)
    }

    /// Full readback of `ghostty_surface_size`: grid dimensions plus the pixel
    /// geometry libghostty derives from them. Used for debug/diagnostics only,
    /// so it is compiled only into debug builds (matching its sole consumer,
    /// `GhosttySurfaceView.debugGeometry()`).
    #if DEBUG
    struct Geometry: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let widthPixels: Int
        let heightPixels: Int
        let cellWidthPixels: Int
        let cellHeightPixels: Int
    }

    /// Read every field of `ghostty_surface_size_s` for the current surface.
    func geometry() -> Geometry {
        let size = ghostty_surface_size(surface)
        return Geometry(
            columns: Int(size.columns),
            rows: Int(size.rows),
            widthPixels: Int(size.width_px),
            heightPixels: Int(size.height_px),
            cellWidthPixels: Int(size.cell_width_px),
            cellHeightPixels: Int(size.cell_height_px))
    }
    #endif

    /// The surface's current live font size, read via libghostty's
    /// inherited-config mechanism (the same path it uses to propagate the
    /// current, possibly runtime-adjusted, font size to a new child split).
    func currentFontSize() -> Float {
        ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
    }
}
