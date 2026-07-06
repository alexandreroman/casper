import AppKit
import CasperCore
import GhosttyKit

/// Process-wide libghostty initialization. `ghostty_init` must run exactly once,
/// before any config or app call (mirrors `CasperGit.Libgit2.ensureInit`). We
/// initialize once and never shut down, which is fine for a long-lived app and
/// the test process.
let ghosttyInitialized: Bool = {
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

    /// Routes app-level actions (new tab/window/split, close) before `onAction`
    /// sees them; a handler that claims an action (returns `true`) suppresses the
    /// existing `onAction` fallback for it. Settable so future features (tabs,
    /// splits, windows) can inject a real handler in place of the default no-op.
    public var actionHandler: GhosttyActionHandler = LoggingActionHandler()

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
        // Load Casper's built-in default theme *first*, before the user's own config,
        // so any user setting still wins. This compensates for macOS libghostty keying
        // the Application-Support config dir on the bundle id (empty for a bundled
        // Casper.app) — without it, the bundle would fall back to the vanilla gray default.
        loadEmbeddedDefaults(into: config)
        ghostty_config_load_default_files(config)
        // Resolve `config-file` includes (e.g. an `?auto/theme.ghostty` theme) pulled in by the
        // user's config. Ghostty's own app runs this before finalize; without it, includes are
        // silently ignored. We deliberately skip `ghostty_config_load_cli_args`: Casper owns its
        // own argument parsing (swift-argument-parser), so its subcommand args are not ghostty config.
        ghostty_config_load_recursive_files(config)
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

    /// Load Casper's built-in default terminal theme into `config`.
    ///
    /// libghostty exposes no load-from-string API — only `ghostty_config_load_file`
    /// — so the embedded config is written to a per-process temp file, loaded, then
    /// removed. Never crashes: if the temp file can't be written, the embedded
    /// default is skipped and the terminal still starts with libghostty's default.
    private func loadEmbeddedDefaults(into config: ghostty_config_t) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-default-config-\(ProcessInfo.processInfo.processIdentifier).ghostty")
        do {
            try GhosttyDefaultConfig.text.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            CasperLog.ghostty.warning("failed to write embedded default config; skipping: \(error)")
            return
        }
        // Remove the temp file once loaded; a cleanup failure is harmless, so ignore it.
        defer { try? FileManager.default.removeItem(at: path) }
        ghostty_config_load_file(config, path.path)
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
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Decode a raw libghostty action and route it to `onAction`. Called by the
    /// `action_cb` trampoline on the main thread; returns `true` to tell
    /// libghostty the action was consumed.
    @discardableResult
    func handleAction(_ action: ghostty_action_s) -> Bool {
        let decoded = GhosttyAction.decode(action)
        switch decoded {
        case .newSplit, .newTab, .newWindow, .closeTab, .closeWindow:
            // A handler that claims the action suppresses the onAction fallback;
            // an unclaimed action (the LoggingActionHandler default) falls through
            // to the existing onAction behavior below, unchanged.
            if actionHandler.handle(decoded) { return true }
        default:
            break
        }
        onAction?(decoded)
        return true
    }

    // Teardown contract (residual): `casperGhosttyWakeup` retains the runtime for
    // the duration of its hop to main, so a wakeup already in flight is safe. It
    // does NOT cover a wakeup that *begins* after the runtime is deallocated: the
    // runtime must not be released while libghostty can still deliver wakeups.
    // A full fix — an explicit invalidate/shutdown that frees the app before this
    // object is released — is deferred to the Plan 5 multi-surface lifecycle work.
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
    // Pin the runtime across the hop: retain now (on libghostty's thread) so it
    // cannot be deallocated before the main block runs; the block consumes the
    // +1 via takeRetainedValue. Only the plain UInt address crosses the boundary
    // (a trivial value the compiler can prove is race-free).
    _ = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).retain()
    let address = UInt(bitPattern: userdata)
    DispatchQueue.main.async {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeRetainedValue()
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
    // Cursor shape/visibility are surface-local: they apply directly to the target
    // view and must NOT flow through the app-level `onAction` closure. Handle them
    // here from the per-surface userdata (the same view-recovery mechanism the
    // clipboard callbacks use), leaving every other action to the runtime unchanged.
    switch action.tag {
    case GHOSTTY_ACTION_MOUSE_SHAPE:
        guard let view = surfaceView(from: target) else { return false }
        let shape = action.action.mouse_shape
        MainActor.assumeIsolated { view.setCursorShape(shape) }
        return true
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
        guard let view = surfaceView(from: target) else { return false }
        let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
        MainActor.assumeIsolated { view.setCursorVisibility(visible) }
        return true
    case GHOSTTY_ACTION_SET_TITLE:
        // Capture the OSC window title per-surface, then fall through (no `return`)
        // so the existing app-level `onAction` still runs — AppDelegate sets
        // `NSApp.keyWindow?.title` from it, and that behavior must be preserved.
        if let view = surfaceView(from: target) {
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                view.updateOSCTitle(title)
            }
        }
    default:
        break
    }

    guard let app, let userdata = ghostty_app_userdata(app) else { return false }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    return runtime.handleAction(action)
}

/// Recover the `GhosttySurfaceView` a surface-scoped action targets, from the
/// per-surface `userdata` libghostty stored at surface creation (the view pointer,
/// the same mechanism the clipboard callbacks use).
private func surfaceView(from target: ghostty_target_s) -> GhosttySurfaceView? {
    guard target.tag == GHOSTTY_TARGET_SURFACE,
          let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface) else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
}

// Clipboard callbacks: libghostty hands back the per-surface `userdata` we set
// in `GhosttySurfaceConfiguration` (the hosting `GhosttySurfaceView` pointer),
// which is how these recover the view to reach `NSPasteboard` and complete
// pending requests. `close_surface_cb` uses the same recovery to ask the view
// to close itself (see `casperGhosttyCloseSurface`).

/// Extract the first clipboard entry's UTF-8 payload as a String. libghostty
/// passes an array of `{mime, data}`; Casper writes plain text only.
func clipboardString(from content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> String? {
    guard let content, count > 0, let data = content[0].data else { return nil }
    return String(cString: data)
}

/// Recover the `GhosttySurfaceView` libghostty's clipboard callbacks were
/// configured with (via `GhosttySurfaceConfiguration`'s `userdata`).
private func clipboardView(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
}

/// `read_clipboard_cb`: `bool (*)(void*, ghostty_clipboard_e, void*)`. Called
/// when libghostty needs the system pasteboard's contents (e.g. ⌘V).
func casperGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let view = clipboardView(from: userdata) else {
        return false
    }
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    // Cross the actor boundary as a trivial address (Sendable), like
    // `casperGhosttyWakeup`, rather than sending the raw pointer itself.
    let stateAddress = UInt(bitPattern: state)
    MainActor.assumeIsolated {
        view.surface?.completeClipboardRequest(
            text, state: UnsafeMutableRawPointer(bitPattern: stateAddress), confirmed: true)
    }
    return true
}

/// `confirm_read_clipboard_cb`:
/// `void (*)(void*, const char*, void*, ghostty_clipboard_request_e)`. Called
/// after a paste is decoded, to confirm delivery (e.g. for OSC 52 reads that
/// would otherwise need a user prompt).
func casperGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    // Both guards below "should never happen"; they exist defensively.
    guard let view = clipboardView(from: userdata) else {
        // No view means nothing to complete the request against — the one case
        // that leaves libghostty's paste unresolved.
        CasperLog.ghostty.warning("confirm-read callback fired with unresolved view userdata")
        return
    }
    // A nil string still gets completed (with empty text) so the paste is never
    // left hanging.
    let text = string.map { String(cString: $0) }
    if text == nil {
        CasperLog.ghostty.warning("confirm-read callback fired with unresolved string; completing empty")
    }
    // Cross the actor boundary as a trivial address (Sendable); see
    // `casperGhosttyReadClipboard`.
    let stateAddress = UInt(bitPattern: state)
    // v1: auto-confirm every read (including risky OSC 52 requests); a
    // confirmation dialog is a future refinement.
    MainActor.assumeIsolated {
        view.surface?.completeClipboardRequest(
            text ?? "", state: UnsafeMutableRawPointer(bitPattern: stateAddress), confirmed: true)
    }
}

/// `write_clipboard_cb`:
/// `void (*)(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool)`.
/// Called when libghostty wants to write to the system pasteboard (e.g. ⌘C).
///
/// v1: the `confirm` flag is intentionally NOT gated — writes are applied
/// unconditionally, mirroring the auto-confirm paste policy used for reads
/// (see `casperGhosttyConfirmReadClipboard`). Honoring `confirm` — to keep
/// untrusted terminal output (e.g. OSC 52) from silently overwriting the
/// user's clipboard — is a deferred follow-up, pending a confirmation UI.
func casperGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let text = clipboardString(from: content, count: count) else {
        return
    }
    let pasteboard = NSPasteboard.general
    MainActor.assumeIsolated {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// `close_surface_cb`: `void (*)(void*, bool)`. Called when the terminal's child
/// process exits (Ctrl-D / `exit`, `processAlive == false`) or libghostty otherwise
/// wants the surface torn down; `processAlive` is ignored (both close the pane).
///
/// The close is DEFERRED to the next main-runloop turn (like `casperGhosttyWakeup`):
/// running `applyCloseSurface` synchronously here would re-enter the runtime — mutating
/// SwiftUI state and tearing down views while libghostty is still mid-tick closing this
/// surface — which detaches the sibling panes. Deferring lets the tick finish first.
func casperGhosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    guard let view = clipboardView(from: userdata) else { return }
    DispatchQueue.main.async { [weak view] in
        MainActor.assumeIsolated { view?.requestClose() }
    }
}
