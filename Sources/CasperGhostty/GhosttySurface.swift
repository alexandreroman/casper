import GhosttyKit

/// Owns a libghostty `ghostty_surface_t` and frees it on deinit (same ownership
/// pattern as `CasperGit.Repository`). Main-thread affine; not `Sendable`.
public final class GhosttySurface {
    let surface: ghostty_surface_t

    /// Create a surface hosted in `nsview`. Throws if the runtime has no app or
    /// libghostty returns null.
    public init(
        runtime: GhosttyRuntime,
        configuration: GhosttySurfaceConfiguration,
        nsview: UnsafeMutableRawPointer
    ) throws {
        guard let app = runtime.app else {
            throw GhosttyError(reason: "runtime has no app")
        }
        let created = configuration.withCValue(nsview: nsview) { c in
            ghostty_surface_new(app, &c)
        }
        guard let created else {
            throw GhosttyError(reason: "ghostty_surface_new returned null")
        }
        self.surface = created
    }

    deinit { ghostty_surface_free(surface) }

    /// Set the drawable size in *pixels* (backing-store units).
    public func setSize(widthPixels: UInt32, heightPixels: UInt32) {
        ghostty_surface_set_size(surface, widthPixels, heightPixels)
    }

    public func setContentScale(x: Double, y: Double) {
        ghostty_surface_set_content_scale(surface, x, y)
    }

    public func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    public func draw() { ghostty_surface_draw(surface) }

    /// Committed/IME text (from `NSTextInputClient.insertText`).
    public func sendText(_ text: String) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    @discardableResult
    public func sendKey(_ event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    public func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) {
        _ = ghostty_surface_mouse_button(surface, state, button, mods)
    }

    public func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    public func sendMouseScroll(
        deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t
    ) {
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }
}
