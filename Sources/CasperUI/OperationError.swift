/// The human-readable reason an operation failed: a workspace that could not be
/// created or deleted, a rejected `diff open` or `casper run`, a failed `browser`
/// automation op. Every consumer only reads `message` — the control channel replies
/// with it and the GUI alerts show it — so one type serves them all, and a reason
/// thrown deep in `BrowserCoordinator` or `BrowserCapture` reaches the CLI without
/// being stringified through a second type.
struct OperationError: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}
