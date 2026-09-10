import SwiftUI

@main
struct TokeiMenyuApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            UsageView(model: model)
        } label: {
            HStack(spacing: 3) {
                menuIcon
                Text(model.headline(for: model.provider))
                    .monospacedDigit()
            }
            .help("\(model.provider.rawValue) usage")
        }
        .menuBarExtraStyle(.window)

        Window("About TokeiMenyu", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(model: model)
        }
    }

    private var menuIcon: Image {
        guard let tint = model.provider.tint else {
            return Image(systemName: model.provider.symbol)
        }
        let image = NSImage(systemSymbolName: model.provider.symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [NSColor(tint)]))!
        image.isTemplate = false
        return Image(nsImage: image)
    }
}
