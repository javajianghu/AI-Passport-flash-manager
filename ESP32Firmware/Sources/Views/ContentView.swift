import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FirmwareManagerView()
                .tabItem {
                    Label("固件管理", systemImage: "folder.fill")
                }
                .tag(0)

            FirmwareSquareView()
                .tabItem {
                    Label("固件广场", systemImage: "square.grid.2x2.fill")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
                .tag(2)
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
