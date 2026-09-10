import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)

            VStack(spacing: 6) {
                Text("TokeiMenyu")
                    .font(.title2.weight(.semibold))
                Text("Version \(version)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Text("Claude and Codex usage limits, live in your menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                linkButton("GitHub", url: "https://github.com/lodev09/tokeimenyu")
                linkButton("@lodev09", url: "https://github.com/lodev09")
            }

            Text("MIT License © 2026 Jovanni Lo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .frame(width: 300)
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Button {
            NSWorkspace.shared.open(URL(string: url)!)
        } label: {
            Text(title)
                .font(.callout)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}
