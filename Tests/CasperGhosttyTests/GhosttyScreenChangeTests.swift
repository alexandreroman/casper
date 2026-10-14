#if DEBUG
import AppKit
import XCTest

@testable import CasperGhostty

/// Moving the window to another screen can change its backing scale without AppKit
/// calling `viewDidChangeBackingProperties` (ghostty-org/ghostty#2731), so the
/// screen-change observer re-pushes the pixel size along with the content scale, as
/// upstream's `windowDidChangeScreen` does. Without it libghostty keeps the pixel size
/// of the screen the window left.
///
/// Runs on the shared `withRealSurface` harness: the size push is guarded on a live
/// surface, which the `.forTesting()` runtime never creates.
final class GhosttyScreenChangeTests: XCTestCase {
    @MainActor
    func testScreenChangeRepushesTheSurfaceSize() throws {
        try withRealSurface { view, _ in
            let pushesBefore = view.debugSizePushCount

            NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: view.window)
            settle(0.1)

            XCTAssertGreaterThan(view.debugSizePushCount, pushesBefore)
        }
    }
}
#endif
