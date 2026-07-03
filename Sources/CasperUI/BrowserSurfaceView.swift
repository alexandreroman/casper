import CasperCore
import CasperGhostty
import SwiftUI
import WebKit

/// A minimal browser surface: an address bar + reload/back/forward over the
/// persistent `WKWebView` cached by `Surface.id`. Aimed at previewing a
/// `localhost:PORT` app started by the agent.
struct BrowserSurfaceView: View {
    @Bindable var model: AppModel
    let surface: Surface
    @State private var address: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { model.webView(for: surface)?.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                Button(action: { model.webView(for: surface)?.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                Button(action: { model.webView(for: surface)?.reload() }) {
                    Image(systemName: "arrow.clockwise")
                }
                TextField("localhost:3000", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { navigate() }
            }
            .padding(6)
            .buttonStyle(.borderless)

            if let web = model.webView(for: surface) {
                PersistentNSViewHost(view: web).id(surface.id)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
        .onAppear {
            if case .browser(let url) = surface.kind, address.isEmpty {
                address = url.absoluteString == "about:blank" ? "" : url.absoluteString
            }
        }
    }

    private func navigate() {
        guard let url = Self.normalize(address) else { return }
        model.webView(for: surface)?.load(URLRequest(url: url))
        model.setBrowserURL(surface.id, url)
    }

    /// Normalize a bare address into a URL: add `http://` when no scheme is given.
    static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "http://" + trimmed)
    }
}
