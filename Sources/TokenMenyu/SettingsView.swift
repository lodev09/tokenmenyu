import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Refresh every", selection: $model.refreshInterval) {
                Text("2 minutes").tag(TimeInterval(120))
                Text("5 minutes").tag(TimeInterval(300))
                Text("10 minutes").tag(TimeInterval(600))
                Text("15 minutes").tag(TimeInterval(900))
                Text("30 minutes").tag(TimeInterval(1800))
                Text("1 hour").tag(TimeInterval(3600))
            }

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize()
    }
}
