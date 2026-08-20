import AppKit
import CasperCore

/// Applying a clipboard write libghostty asked for, and the confirmation that gates an
/// untrusted one.
///
/// libghostty raises the `confirm` flag on `write_clipboard_cb` when the write comes from
/// the terminal's own output (an OSC 52 escape sequence) rather than from a user gesture
/// such as ⌘C. Anything a Casper terminal prints can emit that sequence — a `cat`ed file,
/// an agent's output, a dependency's build log — so an untrusted write only reaches the
/// pasteboard with the user's explicit approval.
@MainActor
enum GhosttyClipboardWrite {
    /// Whether an untrusted write may proceed. Production asks the user with a modal
    /// confirmation; tests substitute a closure, since an `NSAlert` cannot run under XCTest
    /// and the decision — not its presentation — is what the behavior rests on.
    static var approveUntrusted: @MainActor (String) -> Bool = presentConfirmation

    /// Put `text` on `pasteboard`, gating the write behind `approveUntrusted` when
    /// libghostty flagged it as untrusted.
    ///
    /// `pasteboard` is a parameter so tests write to a pasteboard of their own rather than
    /// to the developer's clipboard.
    static func apply(_ text: String, confirm: Bool, to pasteboard: NSPasteboard = .general) {
        if confirm, !approveUntrusted(text) {
            CasperLog.ghostty.notice("denied an untrusted clipboard write of \(text.count, privacy: .public) characters")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// The production confirmation: Ghostty's own OSC 52 write prompt
    /// (`ClipboardConfirmationView` with `Ghostty.ClipboardRequest.osc_52_write`) rendered as
    /// an `NSAlert` — same wording, same caution framing, same preview of the content.
    ///
    /// One deliberate deviation: Ghostty binds Return to "Allow". Casper leaves the
    /// consequential button off the Return key, as its other destructive alerts do, because
    /// this prompt is raised by output the user never asked for and can appear under their
    /// hands mid-typing — a stray Return must not grant clipboard access.
    private static func presentConfirmation(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "An application is attempting to write to the clipboard."
        alert.informativeText = "The content to write is shown below."
        alert.accessoryView = GhosttyClipboardPrompt.contentPreview(text)
        alert.addButton(withTitle: "Deny")
        let allowButton = alert.addButton(withTitle: "Allow")
        allowButton.hasDestructiveAction = true
        allowButton.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }
}
