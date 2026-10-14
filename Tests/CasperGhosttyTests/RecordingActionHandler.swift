@testable import CasperGhostty

/// Stands in for `CasperUI.LayoutActionHandler`, which this module cannot see: records
/// every app-level action the runtime offers it and claims those `claims` accepts — all
/// of them by default.
final class RecordingActionHandler: GhosttyActionHandler {
    private let claims: (GhosttyAction) -> Bool
    private(set) var actions: [GhosttyAction] = []

    init(claiming claims: @escaping (GhosttyAction) -> Bool = { _ in true }) {
        self.claims = claims
    }

    func handle(_ action: GhosttyAction) -> Bool {
        actions.append(action)
        return claims(action)
    }
}
