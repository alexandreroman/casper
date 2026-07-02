import AppKit

/// GUI entry point invoked from the single-binary fork in `main.swift`.
public enum CasperUI {
    @MainActor
    public static func runApp() -> Never {
        NSApplication.shared.setActivationPolicy(.regular)
        CasperApp.main()
        fatalError("CasperApp.main() does not return")
    }
}
