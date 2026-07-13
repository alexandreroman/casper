import SwiftUI

/// SwiftUI environment flag for whether the hosting window is visible on screen.
/// Injected once at the sidebar root from `AppModel.isWindowVisible`; read by
/// the continuously-animating sidebar glyphs so they suspend when the window is
/// minimized, occluded, or on another Space. Defaults `true` so any view read
/// outside the injected hierarchy (previews, detached hosts) animates normally.
private struct WindowVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowVisible: Bool {
        get { self[WindowVisibleKey.self] }
        set { self[WindowVisibleKey.self] = newValue }
    }
}
