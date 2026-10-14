import AppKit

extension NSWindow {
    /// A borderless window parked far off-screen, at (-100_000, -100_000), for hosting
    /// a view that must lay out and run without being seen. Hosting only needs a
    /// non-nil `window`, so the window is never ordered on-screen: an ordered window
    /// this far out joins Mission Control's layout, its bounding box then spans
    /// ~101,000 px and every real window is scaled to nothing — see the
    /// offscreen-host-windows-unordered note. Unordered, it can never become key and
    /// steal keyboard focus.
    ///
    /// `isReleasedWhenClosed` is cleared: a programmatically created window releases
    /// itself on `close()` by default, which would over-release the ARC-owned
    /// reference the caller holds.
    static func offscreenHost(size: NSSize) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -100_000, y: -100_000), size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
