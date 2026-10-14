import Foundation
import GhosttyKit
import XCTest
import CasperTestSupport
@testable import CasperGhostty

final class GhosttyRuntimeTrampolineTests: XCTestCase {
    /// The real libghostty `action_cb` typedef carries no `userdata` argument, so
    /// the C trampoline recovers the runtime via `ghostty_app_userdata(app)` and
    /// forwards to `handleAction(_:)`. That handoff needs a live app, so here we
    /// test the pure routing unit directly: a decoded action reaches `onAction`.
    func testHandleActionRoutesDecodedActionToOnAction() {
        // A runtime built without touching libghostty app creation.
        let runtime = GhosttyRuntime.forTesting()
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertEqual(received, .render)
    }

    func testHandleActionReturnsTrueWithoutObserver() {
        let runtime = GhosttyRuntime.forTesting()

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RENDER

        XCTAssertTrue(runtime.handleAction(action))
    }

    /// The default `actionHandler` (`LoggingActionHandler`) claims no app-level
    /// action, so `handleAction` must still fall through to `onAction`.
    func testHandleActionFallsThroughToOnActionWhenHandlerDoesNotClaim() {
        let runtime = GhosttyRuntime.forTesting()
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_TAB

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertEqual(received, .newTab)
    }

    /// A handler that claims the action (returns `true`) must suppress the
    /// existing `onAction` fallback for it.
    func testHandleActionSuppressesOnActionWhenHandlerClaims() {
        let runtime = GhosttyRuntime.forTesting()
        runtime.actionHandler = ClaimingActionHandler(claimed: .newTab)
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_NEW_TAB

        let handled = runtime.handleAction(action)

        XCTAssertTrue(handled)
        XCTAssertNil(received)
    }

    /// `SET_TITLE` and `SHOW_CHILD_EXITED` are delivered surface-locally and must
    /// terminate inside the trampoline, never reaching the runtime — otherwise the
    /// payload gets decoded a second time on the action hot path (OSC titles fire on
    /// every shell prompt). Driving a real surface-tagged target needs a live surface,
    /// which is flaky headless, so this pins the branch from its app-tagged side: with
    /// no recoverable view *and* no app to fall back to, the tags must still report
    /// consumed, which only holds if the trampoline returns before the runtime handoff.
    func testSurfaceScopedActionsAreConsumedInsideTheTrampoline() {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP

        for tag in [GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SHOW_CHILD_EXITED] {
            var action = ghostty_action_s()
            action.tag = tag

            XCTAssertTrue(casperGhosttyAction(nil, target, action), "tag \(tag.rawValue) must be consumed")
        }
    }

    /// libghostty answers a colour-scheme change with a soft `RELOAD_CONFIG` and
    /// pushes nothing itself; the runtime must claim it. Without an app (the
    /// test-only runtime) there is no config to push, and claiming must not crash.
    func testReloadConfigIsClaimedWithoutAnApp() {
        let runtime = GhosttyRuntime.forTesting()
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        XCTAssertTrue(runtime.handleReloadConfig(target: target))
    }

    private let reloadConfig = GhosttyAction.other(tag: GHOSTTY_ACTION_RELOAD_CONFIG.rawValue)
    private let configChange = GhosttyAction.other(tag: GHOSTTY_ACTION_CONFIG_CHANGE.rawValue)

    /// With a live app the trampoline must claim `RELOAD_CONFIG` itself (the nil-app
    /// fallthrough would return false) and never forward it to `onAction`: it is
    /// plumbing, not an app action. Pushing the stored config must not crash.
    func testReloadConfigTrampolineClaimsWithoutReachingOnAction() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        let runtime = try makeIsolatedRuntime()
        var received: [GhosttyAction] = []
        runtime.onAction = { received.append($0) }
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RELOAD_CONFIG

        XCTAssertTrue(casperGhosttyAction(runtime.app, target, action))
        runtime.tick()
        XCTAssertFalse(received.contains(reloadConfig), "unexpected actions: \(received)")
        // Pushing the stored config is what makes libghostty announce CONFIG_CHANGE.
        XCTAssertTrue(received.contains(configChange), "config was not pushed: \(received)")
    }

    /// Drives libghostty's own app-targeted `RELOAD_CONFIG` (raised by the scheme
    /// change) through the trampoline into `ghostty_app_update_config`, both ways.
    @MainActor
    func testSetColorSchemeOnLiveAppAnswersReloadsWithoutReachingOnAction() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        let runtime = try makeIsolatedRuntime()
        var received: [GhosttyAction] = []
        runtime.onAction = { received.append($0) }

        runtime.setColorScheme(dark: true, surfaces: [])
        runtime.tick()
        runtime.setColorScheme(dark: false, surfaces: [])
        runtime.tick()

        XCTAssertFalse(received.contains(reloadConfig), "unexpected actions: \(received)")
        XCTAssertTrue(received.contains(configChange), "config was not pushed: \(received)")
    }

    /// The theme files live in `~/Library/Caches`, which a cleaner may empty while the app
    /// runs; libghostty re-reads the selected file on every scheme switch, so each switch
    /// must put them back.
    @MainActor
    func testSetColorSchemeRewritesPurgedThemeFiles() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        let directory = makeTemporaryDirectory(prefix: "casper-runtime-themes")
        let runtime = try GhosttyRuntime(themeDirectory: directory, loadUserFiles: { _ in })
        let paths = GhosttyThemeFiles.Paths(
            light: directory.appendingPathComponent("casper-light"),
            dark: directory.appendingPathComponent("casper-dark"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.light.path))
        try FileManager.default.removeItem(at: directory)

        runtime.setColorScheme(dark: true, surfaces: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.light.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.dark.path))
    }

    @MainActor
    func testSetColorSchemeWithoutAnAppIsANoOp() {
        GhosttyRuntime.forTesting().setColorScheme(dark: true, surfaces: [])
    }
}

/// Stub `GhosttyActionHandler` that claims exactly one action, for testing
/// `handleAction`'s fallback-suppression path.
private struct ClaimingActionHandler: GhosttyActionHandler {
    let claimed: GhosttyAction

    func handle(_ action: GhosttyAction) -> Bool {
        action == claimed
    }
}
