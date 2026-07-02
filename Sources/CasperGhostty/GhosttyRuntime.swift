import AppKit
import GhosttyKit

/// Process-wide libghostty initialization. `ghostty_init` must run exactly once,
/// before any config or app call (mirrors `CasperGit.Libgit2.ensureInit`). We
/// initialize once and never shut down, which is fine for a long-lived app and
/// the test process.
private let ghosttyInitialized: Bool = {
    // ghostty_init(argc, argv): hand libghostty the real process arguments.
    ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
}()

/// Owns a libghostty `ghostty_app_t` and the C runtime callbacks, translating
/// decoded actions into a Swift `onAction` closure.
///
/// Main-thread affine and deliberately **not** `Sendable`: like all AppKit state
/// (and `CasperGit.Repository`), instances must be used from the main thread. The
/// one exception is `wakeup_cb`, which libghostty may invoke off the main thread;
/// its trampoline only marshals back to main before touching the runtime.
public final class GhosttyRuntime {
    /// The raw libghostty app handle, consumed by `GhosttySurface` (Task 4). Nil
    /// only for the test-only `forTesting()` runtime, which creates no app.
    private(set) var app: ghostty_app_t!

    /// Invoked on the main thread with each decoded runtime action.
    public var onAction: ((GhosttyAction) -> Void)?

    /// Build a runtime and create the libghostty app with the runtime callbacks.
    /// Throws `GhosttyError` if config creation or app creation fails.
    public init() throws {
        // Accepted exception to the never-crash policy: a failed process-wide
        // `ghostty_init` leaves libghostty unusable, so there is nothing to recover.
        precondition(ghosttyInitialized, "ghostty_init failed")

        guard let config = ghostty_config_new() else {
            throw GhosttyError(reason: "ghostty_config_new returned null")
        }
        defer { ghostty_config_free(config) }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = casperGhosttyWakeup
        runtimeConfig.action_cb = casperGhosttyAction
        runtimeConfig.read_clipboard_cb = casperGhosttyReadClipboard
        runtimeConfig.confirm_read_clipboard_cb = casperGhosttyConfirmReadClipboard
        runtimeConfig.write_clipboard_cb = casperGhosttyWriteClipboard
        runtimeConfig.close_surface_cb = casperGhosttyCloseSurface

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            throw GhosttyError(reason: "ghostty_app_new returned null")
        }
        self.app = app
    }

    /// Test-only constructor: a runtime with no libghostty app, used to exercise
    /// the pure action routing without a GPU/GUI session.
    static func forTesting() -> GhosttyRuntime {
        GhosttyRuntime(uninitialized: ())
    }

    private init(uninitialized: ()) {
        self.app = nil
    }

    /// Drain libghostty's pending work. Main thread only; no-op without an app.
    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Decode a raw libghostty action and route it to `onAction`. Called by the
    /// `action_cb` trampoline on the main thread; returns `true` to tell
    /// libghostty the action was consumed.
    @discardableResult
    func handleAction(_ action: ghostty_action_s) -> Bool {
        onAction?(GhosttyAction.decode(action))
        return true
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }
}

// MARK: - C trampolines
//
// C function pointers cannot capture Swift context. libghostty passes our
// `userdata` (the unretained runtime pointer set in the runtime config) to most
// callbacks; `action_cb` is the exception — its v1.3.1 typedef carries no
// userdata, so the trampoline recovers the runtime via `ghostty_app_userdata`.

/// `wakeup_cb`: `void (*)(void*)`. May fire off the main thread, so it only
/// marshals to main before touching the runtime. It captures the opaque pointer
/// (which is `Sendable`) rather than the non-`Sendable` runtime object.
func casperGhosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    // Hop to main across the raw address as a plain `UInt`: a trivial value the
    // compiler can prove is race-free, unlike sending the pointer or the runtime.
    let address = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
        runtime.tick()
    }
}

/// `action_cb`: `bool (*)(ghostty_app_t, ghostty_target_s, ghostty_action_s)`.
/// No userdata argument, so recover the runtime from the app handle. Always
/// invoked on the main thread by libghostty during a `ghostty_app_tick`.
func casperGhosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    guard let app, let userdata = ghostty_app_userdata(app) else { return false }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    return runtime.handleAction(action)
}

// Minimal clipboard/close callbacks: non-null so libghostty never dereferences a
// null pointer. Full copy/paste fidelity is a Plan 5 refinement.

/// `read_clipboard_cb`: `bool (*)(void*, ghostty_clipboard_e, void*)`.
func casperGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    false  // Deny clipboard reads by default in Plan 4.
}

/// `confirm_read_clipboard_cb`:
/// `void (*)(void*, const char*, void*, ghostty_clipboard_request_e)`.
func casperGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {}

/// `write_clipboard_cb`:
/// `void (*)(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool)`.
func casperGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {}

/// `close_surface_cb`: `void (*)(void*, bool)`.
func casperGhosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
