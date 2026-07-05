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
    @FocusState private var addressFocused: Bool

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
                TextField("localhost:3000", text: $coordinator.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { navigate() }
            }
            .padding(6)
            .buttonStyle(.borderless)
            // Surface the coordinator's editing state so a navigation finishing
            // mid-edit doesn't overwrite the user's in-progress address text.
            .onChange(of: addressFocused) { _, focused in coordinator.isEditingAddress = focused }

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
