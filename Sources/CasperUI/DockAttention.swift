import AppKit

/// The Dock-icon side of Casper's attention subsystem: the bounce that pulls the
/// eye to a hidden window, and the badge that counts workspaces still carrying an
/// unread notification.
///
/// A protocol so `AppModel` can be exercised headlessly — the tests never touch
/// `NSApp`.
@MainActor
protocol DockAttentionPresenting {
    /// Start bouncing the Dock icon. A no-op while a bounce is already outstanding or
    /// while Casper is the active application, so repeated notifications cannot stack
    /// up several requests and a frontmost app never latches one.
    func bounce()

    /// Stop an outstanding bounce, if there is one.
    func cancelBounce()

    /// Show `count` on the Dock badge, or clear the badge when it is zero.
    func updateBadge(count: Int)
}

/// The slice of `NSApplication` that `DockAttention` drives. A seam under the
/// presenter, so its request-id latch — including the rule that nothing is ever
/// requested while Casper is active — can be tested without a running application.
@MainActor
protocol DockAttentionBackend {
    /// True while Casper is the active (frontmost) application.
    var isApplicationActive: Bool { get }

    /// Start an attention request, answering the identifier that cancelling it needs,
    /// or nil when there is no running application to bounce.
    func requestAttention() -> Int?

    /// Cancel the attention request started under `id`.
    func cancelAttention(_ id: Int)

    /// Set the Dock badge text, clearing the badge with nil.
    func setBadgeLabel(_ label: String?)
}

/// The production backend, driving `NSApp` directly. `NSApp` is nil outside a
/// running application (a headless CLI, a test), where every call is a no-op.
@MainActor
struct AppKitDockAttentionBackend: DockAttentionBackend {
    var isApplicationActive: Bool { NSApp?.isActive ?? false }

    func requestAttention() -> Int? {
        // `.criticalRequest` keeps bouncing until the app is activated, unlike
        // `.informationalRequest`'s single bounce: a workspace waiting on the user
        // should stay visible until the user actually comes back.
        NSApp?.requestUserAttention(.criticalRequest)
    }

    func cancelAttention(_ id: Int) {
        NSApp?.cancelUserAttentionRequest(id)
    }

    func setBadgeLabel(_ label: String?) {
        NSApp?.dockTile.badgeLabel = label
    }
}

/// The production `DockAttentionPresenting`, owning the request-id latch over a
/// `DockAttentionBackend`.
@MainActor
final class DockAttention: DockAttentionPresenting {
    private let backend: DockAttentionBackend

    /// The identifier of the outstanding attention request, which is what cancelling
    /// it needs. Non-nil exactly while a bounce request is alive.
    private var attentionRequestID: Int?

    init(backend: DockAttentionBackend = AppKitDockAttentionBackend()) {
        self.backend = backend
    }

    func bounce() {
        // AppKit's contract for `requestUserAttention` is to call it only when the app
        // is NOT active. While Casper is frontmost the request would do nothing visible,
        // yet latching one here would swallow the next real bounce: nothing releases the
        // latch, since `applicationDidBecomeActive` never fires for an app that never
        // left the front.
        guard attentionRequestID == nil, !backend.isApplicationActive else { return }
        attentionRequestID = backend.requestAttention()
    }

    func cancelBounce() {
        guard let id = attentionRequestID else { return }
        attentionRequestID = nil
        backend.cancelAttention(id)
    }

    func updateBadge(count: Int) {
        backend.setBadgeLabel(count > 0 ? String(count) : nil)
    }
}
