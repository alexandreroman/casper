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
    private(set) var app: ghostty_app_t?

    /// Invoked on the main thread with each decoded runtime action.
    public var onAction: ((GhosttyAction) -> Void)?

    /// Routes app-level actions (new tab/window/split, close) before `onAction`
    /// sees them; a handler that claims an action (returns `true`) suppresses the
    /// existing `onAction` fallback for it. The app injects `LayoutActionHandler`
    /// here (`CasperUI.AppDelegate`), which claims `.newTab`, `.newSplit` and
    /// `.closeTab`. The default `LoggingActionHandler` claims nothing, which is what
    /// tests and the window between runtime creation and that injection see.
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

    /// Tell libghostty whether the app is frontmost. Governs cursor blink and
    /// focus-driven animation; does not by itself pause rendering (occlusion
    /// does). No-op without an app (the test-only runtime).
    public func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    /// Decode a raw libghostty action and route it to `onAction`. Called by the
    /// `action_cb` trampoline on the main thread; returns `true` to tell
    /// libghostty the action was consumed.
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

    // Teardown contract (known limitation): `casperGhosttyWakeup` retains the runtime
    // for the duration of its hop to main, so a wakeup already in flight is safe. It
    // does NOT cover a wakeup that *begins* after the runtime is deallocated: the
    // runtime must not be released while libghostty can still deliver wakeups. The app
    // holds one runtime for its whole lifetime, so the window never opens in practice;
    // closing it for good would take an explicit invalidate/shutdown that frees the app
    // before this object is released. `GhosttySurfaceView.invalidate()` narrows the same
    // class of hazard one level down, freeing a surface while its view is still alive.
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
    // Surface-local actions apply directly to the target view and must NOT flow through
    // the app-level `onAction` closure. Handle them here from the per-surface userdata
    // (the same view-recovery mechanism the clipboard callbacks use), leaving every
    // other action to the runtime unchanged.
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
        // The OSC window title is per-surface state that agent-state detection reads
        // back via `readOSCTitle()`, so the target view is its only consumer and the
        // action terminates here. Handing a second decoded copy to the app-level
        // `onAction` would allocate a fresh Swift `String` for nobody on every shell
        // prompt — OSC titles carry the agent spinner animation, so this is the action
        // hot path. Reported as consumed even when no view is recoverable, matching the
        // app-level `handleAction`, which claims every action it is given.
        if let view = surfaceView(from: target) {
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            MainActor.assumeIsolated {
                view.updateOSCTitle(title)
            }
        }
        return true
    case GHOSTTY_ACTION_PROGRESS_REPORT:
        // OSC 9;4 progress is the primary agent-state "working" signal: Claude Code
        // brackets a turn with `ESC]9;4;3` … `ESC]9;4;0`. Like SET_TITLE above it is
        // per-surface state whose only consumer is the target view (read back via
        // `readProgressReport()`), so the action terminates here, and is reported as
        // consumed even when no view is recoverable.
        if let view = surfaceView(from: target) {
            // Only the state is kept. The report also carries `progress` (a percentage,
            // -1 when absent), but detection needs liveness, not completion: storing a
            // percentage nothing reads would be dead state.
            let state = progressState(from: action.action.progress_report.state)
            MainActor.assumeIsolated { view.updateProgressReport(state) }
        }
        return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
        // Surface-scoped: deliver the child's exit status to the target view so a
        // lifecycle-hook surface can react — the consumer decides based on the code.
        // Independent of libghostty's own pane teardown, which arrives through the
        // separate `close_surface_cb` callback and is unaffected by this return value.
        // Truncating (not trapping) i32 conversion matches GhosttyAction.decode's
        // handling of this field. Consumed unconditionally, as for SET_TITLE above.
        if let view = surfaceView(from: target) {
            let code = Int32(truncatingIfNeeded: action.action.child_exited.exit_code)
            MainActor.assumeIsolated { view.reportChildExit(code) }
        }
        return true
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

/// Translate libghostty's OSC 9;4 progress state to CasperCore's
/// `AgentProgressState`. The C enum stops here, at the GhosttyKit boundary:
/// CasperCore owns the detection policy but must not depend on GhosttyKit.
private func progressState(from state: ghostty_action_progress_report_state_e) -> AgentProgressState {
    switch state {
    case GHOSTTY_PROGRESS_STATE_REMOVE: return .removed
    case GHOSTTY_PROGRESS_STATE_SET: return .set
    case GHOSTTY_PROGRESS_STATE_ERROR: return .error
    case GHOSTTY_PROGRESS_STATE_INDETERMINATE: return .indeterminate
    case GHOSTTY_PROGRESS_STATE_PAUSE: return .paused
    // A C enum imported into Swift is not exhaustive, so a `default` is required. An
    // unrecognised state reads as `.removed` — "this source says nothing" — which is
    // the conservative choice: a state Casper cannot interpret must never be able to
    // pin a workspace to `working`.
    default: return .removed
    }
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
/// when libghostty needs the system pasteboard's contents (e.g. ⌘V, or an OSC 52
/// read requested by the terminal's own output).
///
/// The text is handed back with `confirmed: false`, as upstream Ghostty does. That
/// flag means "the user has already approved this": `true` short-circuits
/// libghostty's `clipboard-read` policy, so the OSC 52 response is emitted without
/// `confirm_read_clipboard_cb` ever firing and `GhosttyClipboardRead`'s prompt never
/// runs. `false` lets core apply the policy and ask, which is the only thing that
/// makes the gate reachable at all. Confirmation then arrives in
/// `casperGhosttyConfirmReadClipboard`, which is also where an ordinary paste is
/// confirmed on sight.
func casperGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let view = clipboardView(from: userdata) else {
        return false
    }
    // Cross the actor boundary as a trivial address (Sendable), like
    // `casperGhosttyWakeup`, rather than sending the raw pointer itself.
    let stateAddress = UInt(bitPattern: state)
    MainActor.assumeIsolated {
        let text = GhosttyClipboardRead.systemPasteboard.string(forType: .string) ?? ""
        view.surface?.completeClipboardRequest(
            text, state: UnsafeMutableRawPointer(bitPattern: stateAddress), confirmed: false)
    }
    return true
}

/// `confirm_read_clipboard_cb`:
/// `void (*)(void*, const char*, void*, ghostty_clipboard_request_e)`. Called when
/// libghostty's clipboard-read policy wants a decoded read confirmed before its text
/// is delivered.
///
/// Only `GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ` — the terminal's own output asking for
/// the clipboard, with the answer written back to the asking program — raises a prompt.
/// Every other request keeps the confirm-on-sight behaviour: a `..._PASTE` request is
/// libghostty's `clipboard-paste-protection` check on an ordinary ⌘V, and Casper has not
/// implemented that separate prompt, so gating ⌘V here would break pasting outright.
///
/// The OSC 52 prompt is DEFERRED to the next main-queue turn for the reason spelled out
/// above `casperGhosttyWriteClipboard`: it runs modally, and spinning a nested run loop
/// here would park libghostty mid-tick. `DispatchQueue.main.async` is again the right hop
/// rather than the modal-proof `CFRunLoopPerformBlock` route — the guarantee that matters
/// is that the block cannot run inside the current tick, and a prompt queued behind an
/// alert already on screen belongs after it. The request stays pending across that hop,
/// which is exactly what a read the user has not answered yet should be.
func casperGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    // The view guard and the string check below "should never happen"; they exist
    // defensively.
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
    let clipboard = text ?? ""
    // Cross the actor boundary as a trivial address (Sendable); see
    // `casperGhosttyReadClipboard`.
    let stateAddress = UInt(bitPattern: state)
    guard request == GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ else {
        MainActor.assumeIsolated {
            view.surface?.completeClipboardRequest(
                clipboard, state: UnsafeMutableRawPointer(bitPattern: stateAddress), confirmed: true)
        }
        return
    }
    DispatchQueue.main.async { [weak view] in
        MainActor.assumeIsolated {
            // A denied read is completed with empty text rather than abandoned — upstream
            // Ghostty drops the request, but that is the same hazard the nil-string case
            // above guards: an unresolved request leaves libghostty holding pending state
            // and the program that emitted the escape sequence waiting for an answer it
            // will never read. Empty text says "nothing", which is the honest answer.
            let answer = GhosttyClipboardRead.resolveUntrusted(clipboard)
            view?.surface?.completeClipboardRequest(
                answer, state: UnsafeMutableRawPointer(bitPattern: stateAddress), confirmed: true)
        }
    }
}

/// `write_clipboard_cb`:
/// `void (*)(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool)`.
/// Called when libghostty wants to write to the system pasteboard (e.g. ⌘C).
///
/// A user-initiated write (`confirm == false`) is applied straight away. A write
/// libghostty flags as untrusted (`confirm == true` — an OSC 52 sequence in the
/// terminal's output) is confirmed with the user first, and that prompt is DEFERRED
/// to the next main-queue turn, like `casperGhosttyCloseSurface` below: a
/// confirmation runs modally, and spinning a nested run loop here would park
/// libghostty mid-tick. The text is decoded before the hop because `content` only
/// lives for the duration of this call.
///
/// The deferral is `DispatchQueue.main.async` rather than the modal-proof
/// `CFRunLoopPerformBlock` route (`ScriptHookRunner.onMainRunLoop`): a work item that
/// waits behind an alert already on screen is the right outcome here — nothing in
/// libghostty is blocked on this write, and the prompt belongs after that dialog, not
/// stacked on it. What the main queue does guarantee is the part that matters, that
/// the block cannot run inside the current tick.
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
    guard confirm else {
        MainActor.assumeIsolated { GhosttyClipboardWrite.apply(text, confirm: false) }
        return
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { GhosttyClipboardWrite.apply(text, confirm: true) }
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
