import SwiftUI
import UTUVOTypeCore

@main
struct UTUVOTypeIOSApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            DictateView()
                .tabItem { Label("聽寫", systemImage: "mic.fill") }
                .tag(0)
            HistoryListView()
                .tabItem { Label("歷史", systemImage: "clock.arrow.circlepath") }
                .tag(1)
            SettingsScreen()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag(2)
        }
        .tint(Aurora.orange)
        .preferredColorScheme(.dark)
    }
}
