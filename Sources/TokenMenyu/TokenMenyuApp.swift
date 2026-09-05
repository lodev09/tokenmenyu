import SwiftUI

@main
struct TokenMenyuApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsageView(model: model)
        } label: {
            HStack(spacing: 3) {
                ForEach(UsageProvider.allCases) { provider in
                    Image(systemName: provider.symbol)
                    Text(model.headline(for: provider))
                        .monospacedDigit()
                        .help("\(provider.rawValue) usage")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("About TokenMenyu", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: model)
        }
    }
}
