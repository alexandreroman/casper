import AppKit
import CasperCore
import CasperGhostty
import SwiftUI

/// A minimal browser surface: an address bar + reload/back/forward over the
/// persistent `WKWebView` owned by a `BrowserCoordinator` cached by `Surface.id`.
/// Aimed at previewing a `localhost:PORT` app started by the agent.
struct BrowserSurfaceView: View {
    @Bindable var model: AppModel
    let surface: Surface

    var body: some View {
        if let coordinator = model.browserCoordinator(for: surface) {
            BrowserSurfaceContentView(model: model, surface: surface, coordinator: coordinator)
        } else {
            Color(nsColor: .textBackgroundColor)  // not a browser surface
        }
    }

    /// Normalize a bare address into a URL: add `http://` when no scheme is given.
    /// A real scheme (e.g. `https://x.dev`) parses with both `scheme` and `host`
    /// set. A bare `host:port` like `localhost:3000` also parses a `scheme`
    /// (`URLComponents` treats `scheme:opaque-path` as valid syntax without `//`),
    /// but with no `host` — so `host != nil` is the discriminator between a real
    /// scheme and a bare host with a port number that merely looks like one.
    ///
    /// Only `http`/`https` are honored: this is a localhost-preview tool, not a
    /// general browser, so `file://` and other full-privilege schemes are
    /// rejected (returns nil, ignored by the caller) rather than loaded.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let components = URLComponents(string: trimmed), let scheme = components.scheme, components.host != nil {
            guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else { return nil }
            return URL(string: trimmed)
        }
        return URL(string: "http://" + trimmed)
    }
}

/// The body of a browser surface, observing its coordinator so the address bar
/// and navigation buttons re-render as the web view commits navigations. Split
/// out so `@ObservedObject` subscribes to the externally cached coordinator.
private struct BrowserSurfaceContentView: View {
    let model: AppModel
    let surface: Surface
    @ObservedObject var coordinator: BrowserCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { coordinator.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!coordinator.canGoBack)
                Button(action: { coordinator.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!coordinator.canGoForward)
                Button(action: { coordinator.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                AddressField(
                    text: $coordinator.address,
                    onSubmit: { navigate() },
                    onFocusChange: { coordinator.isEditingAddress = $0 }
                )
                .frame(maxWidth: .infinity)
            }
            .padding(6)
            .buttonStyle(.borderless)

            if let error = coordinator.loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
            }

            PersistentNSViewHost(view: coordinator.webView).id(surface.id)
        }
    }

    private func navigate() {
        guard let url = BrowserSurfaceView.normalize(coordinator.address) else { return }
        coordinator.load(url)
        model.setBrowserURL(surface.id, url)
    }
}

/// An `NSTextField` that selects its whole contents on a plain click, giving the
/// standard browser address-bar behavior (click the URL and start typing a
/// replacement).
///
/// The selection is made in the `mouseDown` override, AFTER `super` returns —
/// i.e. after the click's own caret placement — so it is deterministic and never
/// collapsed by the click. Selecting in the delegate's
/// `controlTextDidBeginEditing` is racy by comparison: that fires during the
/// mouse-down tracking loop, so a deferred `selectAll` can run before the caret
/// is placed and get lost. A plain click leaves just a caret and triggers
/// select-all; a click-drag or double-click that produced a real selection is
/// left exactly as the user made it.
private final class SelectAllTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // A plain click leaves just a caret; select the whole address so the user
        // can immediately type a replacement (standard browser address-bar
        // behavior). A click-drag or double-click that produced a real selection
        // is left as the user made it. This runs after super returns — i.e. after
        // the click's own caret placement — so the selection is not collapsed.
        if let editor = currentEditor(), editor.selectedRange.length == 0 {
            editor.selectAll(nil)
        }
    }
}

/// An address bar backed by an `NSTextField` we own outright.
///
/// SwiftUI's `TextField` cannot reliably select all of its text on focus: it
/// owns the field editor and places the insertion point at the end on a later
/// runloop turn, so a deferred `selectAll` either targets the wrong first
/// responder or is immediately overridden — and SwiftUI exposes no selection
/// hook to fix that. By wrapping our own `NSTextField` we regain full control.
/// Select-all-on-click is handled deterministically by `SelectAllTextField` in
/// `mouseDown` (see its note), giving the standard browser address-bar behavior
/// (focus selects the whole URL so the user can type a replacement) with no
/// competing SwiftUI selection logic.
private struct AddressField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField()
        field.placeholderString = "localhost:3000"
        field.bezelStyle = .roundedBezel  // matches the old SwiftUI `.roundedBorder` look
        field.cell?.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        // Stretch to fill the toolbar HStack like the old TextField did.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Refresh the stored parent so the delegate always sees the latest
        // binding and closures.
        context.coordinator.parent = self
        // Never overwrite the field while the user is editing, so a navigation
        // finishing mid-edit doesn't clobber the in-progress address text.
        if !context.coordinator.isEditing && field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressField
        var isEditing = false

        init(parent: AddressField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            parent.onFocusChange(true)
            // Select-all-on-click is handled in `SelectAllTextField.mouseDown`, which
            // is deterministic; doing it here is racy against the click's caret placement.
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Return submits the address instead of inserting a newline.
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
