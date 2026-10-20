import SwiftUI

struct FirmwareSquareView: View {
    @StateObject private var deviceViewModel = DeviceViewModel()

    private let firmwareSquareURL = "https://ai-passport.folotoy.cn/plays/"

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("固件广场")
                .font(.title)
                .fontWeight(.semibold)

            Text("浏览AI Passport 玩法社区")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: {
                if let url = URL(string: firmwareSquareURL) {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("打开固件广场", systemImage: "arrow.up.forward.square")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
