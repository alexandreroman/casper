import CasperCore
import Foundation

/// Process-global launch options, resolved once in `runApp()` before the
/// SwiftUI scene (and thus `AppModel.shared`) come up.
enum AppLaunch {
    @MainActor static var sessionIdentity: SessionIdentity = .default
}
