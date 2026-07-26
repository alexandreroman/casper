import CasperCore
import Foundation
import Sparkle

/// Sparkle auto-update, deliberately inert unless the running bundle is actually
/// configured to receive updates.
///
/// Casper ships ad-hoc-signed: there is no Developer ID certificate and no
/// notarization, so Sparkle cannot lean on code-signing continuity to decide
/// whether a downloaded archive really came from this project. Trust rests
/// entirely on the EdDSA signature carried by each appcast item, checked against
/// the `SUPublicEDKey` baked into the bundle. A feed URL without that key would
/// therefore be an unauthenticated update channel, which is why both keys are
/// required before any Sparkle object is created. Sparkle itself refuses the
/// situation loudly: a controller built without them logs errors and puts a modal
/// alert in front of the user.
///
/// That gate is also what keeps development quiet: only the release bundle
/// (`Packaging/Info.plist`) carries both keys, the dev bundle
/// (`Packaging/Info-dev.plist`) carries neither, and a bare `swift run casper`
/// has no bundle at all.
@MainActor
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    /// Whether this bundle declares both the appcast feed and the public key that
    /// authenticates it. Fixed for the lifetime of the process.
    let isEnabled: Bool

    private var controller: SPUStandardUpdaterController?

    private init() {
        isEnabled = Self.hasNonEmptyInfoString(forKey: "SUFeedURL")
            && Self.hasNonEmptyInfoString(forKey: "SUPublicEDKey")
    }

    /// Starts the updater; from then on Sparkle schedules its own background checks.
    /// Called once at launch, but safe to call again — the controller is created at
    /// most once.
    func start() {
        guard controller == nil else { return }
        guard isEnabled else {
            CasperLog.app.info("software updates off: bundle declares no SUFeedURL/SUPublicEDKey pair")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Runs a user-initiated check, showing Sparkle's progress and update windows.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    private static func hasNonEmptyInfoString(forKey key: String) -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.isEmpty
    }
}
