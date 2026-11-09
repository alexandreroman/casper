import Foundation
import GhosttyKit

/// Owns a libghostty `ghostty_surface_t` and frees it on deinit (same ownership
/// pattern as `CasperGit.Repository`). Main-thread affine; not `Sendable`.
final class GhosttySurface {
    let surface: ghostty_surface_t

    /// Pins the runtime's `ghostty_app_t` alive for as long as this surface
    /// exists, since the surface belongs to that app and frees itself into it.
    private let runtime: GhosttyRuntime

    /// Create a surface hosted in `nsview`, at the hosting window's `scaleFactor`.
    /// `userdata` is handed back verbatim to libghostty's clipboard/close callbacks —
    /// pass the view pointer so those callbacks can recover the owning
    /// `GhosttySurfaceView`. Throws if the runtime has no app or libghostty returns null.
    init(
        runtime: GhosttyRuntime,
        configuration: GhosttySurfaceConfiguration,
        nsview: UnsafeMutableRawPointer,
        userdata: UnsafeMutableRawPointer?,
        scaleFactor: Double
    ) throws {
        guard let app = runtime.app else {
            throw GhosttyError(reason: "runtime has no app")
        }
        let created = configuration.withCValue(nsview: nsview, userdata: userdata, scaleFactor: scaleFactor) { c in
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

    /// Tell libghostty which side of a conditional (`light:…,dark:…`) config this
    /// surface renders; libghostty then raises a surface-targeted `RELOAD_CONFIG`.
    func setColorScheme(dark: Bool) {
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    /// Tell libghostty whether this surface is occluded (off-screen). Note:
    /// libghostty's `ghostty_surface_set_occlusion` parameter is **`visible`**
    /// (true = on-screen → render; false = occluded → pause) — the INVERSE of our
    /// `occluded`, so we pass the negation. Confirmed against the pinned revision's
    /// `src/apprt/embedded.zig`: `ghostty_surface_set_occlusion(surface, visible)`.
    /// When occluded, libghostty pauses the surface's render thread; clearing it
    /// resumes rendering. Balances `set_display_id`, which arms the render loop.
    func setOcclusion(_ occluded: Bool) {
        ghostty_surface_set_occlusion(surface, !occluded)
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

    /// Send `event` with `text` attached as its committed text (nil for a key that
    /// commits none, such as every release).
    ///
    /// `ghostty_input_key_s.text` is a borrowed C pointer that must stay valid for
    /// the whole `ghostty_surface_key` call, so the text is attached here, inside the
    /// `withCString` frame that owns the buffer, rather than by a caller building an
    /// event whose pointer is already dangling by the time it sends it.
    @discardableResult
    func sendKey(_ event: ghostty_input_key_s, text: String?) -> Bool {
        guard let text else { return sendKey(event) }
        return text.withCString { pointer in
            var event = event
            event.text = pointer
            return sendKey(event)
        }
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

    /// Answer a pending clipboard request with `contents` (the representations served) and
    /// `available` (the MIME types the clipboard offers, for a request that asked for a
    /// listing). `state` is the opaque token libghostty handed to the read or confirm
    /// callback; it must be passed back unchanged.
    ///
    /// `confirmed` means "the user has already approved this".
    ///
    /// libghostty borrows every pointer in `ghostty_clipboard_complete_s` for the duration of
    /// the call only — including a confirmation callback it may fire synchronously from
    /// inside it — so the C copies are owned here and freed once the call returns, as
    /// upstream Ghostty does.
    func completeClipboardRequest(
        _ contents: [GhosttyClipboardContent],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cBuffers: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            cBuffers.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for content in contents {
            guard let mime = strdup(content.mime) else { continue }
            cStrings.append(mime)
            // Never a zero-byte allocation, so `data` is a valid pointer even for empty text.
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(content.data.count, 1), alignment: 1)
            cBuffers.append(buffer)
            content.data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: content.data.count))
            cContents.append(ghostty_clipboard_content_s(
                mime: mime, data: buffer.assumingMemoryBound(to: CChar.self), len: content.data.count))
        }

        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let copy = strdup(mime) else { continue }
            cStrings.append(copy)
            cAvailable.append(UnsafePointer(copy))
        }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var complete = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    // Casper's gate offers no "remember this" choice, so no kitty session
                    // grant is ever recorded.
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    /// Refuse a pending clipboard request. Core answers the asking program itself where its
    /// protocol expects an answer: empty contents for an OSC 52 read, `EPERM` for a kitty
    /// request; a denied paste simply does not happen.
    func denyClipboardRequest(state: UnsafeMutableRawPointer?) {
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    /// Point the surface at the display it is shown on, so libghostty drives its
    /// internal display link at that screen's refresh rate.
    func setDisplayID(_ id: UInt32) {
        ghostty_surface_set_display_id(surface, id)
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
        // Decode straight off libghostty's buffer: an intermediate `Data` would copy
        // the whole scrollback (megabytes with `scrollback: true`) a second time, and
        // this sits on the agent-state detection poll path. The `defer` above frees the
        // buffer only after the String has been built.
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(out.text_len)),
                      as: UTF8.self)
    }

    /// The surface's current live font size, read via libghostty's
    /// inherited-config mechanism (the same path it uses to propagate the
    /// current, possibly runtime-adjusted, font size to a new child split).
    func currentFontSize() -> Float {
        ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
    }
}
