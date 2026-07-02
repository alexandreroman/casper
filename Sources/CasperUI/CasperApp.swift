import SwiftUI

struct CasperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
