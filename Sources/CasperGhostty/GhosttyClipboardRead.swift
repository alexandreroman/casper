import AppKit
import CasperCore

/// The confirmation that gates a clipboard read the terminal asked for itself.
///
/// libghostty routes an OSC 52 read — an escape sequence in the terminal's own output that
/// asks for the clipboard and gets the answer written back to the program's stdin — through
/// `confirm_read_clipboard_cb`. Anything a Casper terminal prints can emit that sequence: a
/// `cat`ed file, an agent's output, a dependency's build script. The answer goes straight
/// to whoever asked, so an untrusted read only sees the clipboard with the user's explicit
/// approval.
@MainActor
enum GhosttyClipboardRead {
    /// Whether an untrusted read may proceed. Production asks the user with a modal
    /// confirmation; tests substitute a closure, since an `NSAlert` cannot run under XCTest
    /// and the decision — not its presentation — is what the behavior rests on.
    static var approveUntrusted: @MainActor (String) -> Bool = presentConfirmation

    /// The pasteboard a clipboard read is answered from.
    ///
    /// libghostty's read callback takes no pasteboard argument the way
    /// `GhosttyClipboardWrite.apply(_:confirm:to:)` takes one, so the seam is this property
    /// instead — again so tests do not touch the developer's clipboard.
    static var systemPasteboard: NSPasteboard = .general

    /// The text to answer an untrusted read of `text` with: `text` itself once the user
    /// approves, an empty string when they deny.
    ///
    /// The clipboard text is a parameter rather than read from `NSPasteboard` here, so tests
    /// exercise the gate without touching the developer's clipboard.
    static func resolveUntrusted(_ text: String) -> String {
        guard approveUntrusted(text) else {
            CasperLog.ghostty.notice("denied an untrusted clipboard read of \(text.count, privacy: .public) characters")
            return ""
        }
        return text
    }

    /// The production confirmation: Ghostty's own OSC 52 read prompt
    /// (`ClipboardConfirmationView` with `Ghostty.ClipboardRequest.osc_52_read`), with this
    /// gate's wording in the shared alert.
    private static func presentConfirmation(_ text: String) -> Bool {
        GhosttyClipboardPrompt.confirm(
            message: "An application is attempting to read from the clipboard.",
            informative:
                "The current clipboard contents are shown below. Allowing this sends them to the application.",
            content: text)
    }
}

/// The presentation both clipboard gates share.
@MainActor
enum GhosttyClipboardPrompt {
    /// Ask the user to approve a clipboard access the terminal's own output requested,
    /// showing `content` as the text at stake. Returns whether they allowed it.
    ///
    /// Rendered as an `NSAlert`, taking its wording, caution framing and content preview
    /// from Ghostty's own prompt (`ClipboardConfirmationView`). One deliberate deviation:
    /// Ghostty binds Return to "Allow", while Casper leaves the consequential button off
    /// the Return key, as its other destructive alerts do. Both prompts are raised by
    /// output the user never asked for and can appear under their hands mid-typing, so a
    /// stray Return must not hand a password or a token to whatever printed the escape
    /// sequence.
    static func confirm(message: String, informative: String, content: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informative
        alert.accessoryView = contentPreview(content)
        alert.addButton(withTitle: "Deny")
        let allowButton = alert.addButton(withTitle: "Allow")
        allowButton.hasDestructiveAction = true
        allowButton.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The clipboard content at stake, read-only in a fixed scrolling box — Ghostty shows the
    /// same preview in a monospaced `TextEditor`. Scrolling, rather than inline text, keeps
    /// arbitrary terminal output from stretching the alert past the screen.
    private static func contentPreview(_ text: String) -> NSView {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 96)
        let textView = NSTextView(frame: frame)
        textView.string = text
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }
}
