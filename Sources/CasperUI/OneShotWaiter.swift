/// A one-shot main-actor waiter: `wait()` suspends until the first
/// `resume(returning:)` and returns its value; later resumes are no-ops. Handles a
/// resume arriving before `wait()`. Used to race an awaited event against its
/// timeout: the render-readiness JavaScript in `BrowserCapture.waitForFullRender`,
/// and a reload's navigation in `BrowserCoordinator.reload(waitingUpTo:)`.
@MainActor
final class OneShotWaiter<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resume(returning value: Value) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
