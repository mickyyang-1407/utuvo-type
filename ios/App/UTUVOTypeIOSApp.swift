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

    init() {
        #if DEBUG
        // 鍵盤截圖姿態：主 app 收 launch arg `-utuvo.type.keyboard.debugPose recording|arc`，
        // 經 cfprefsd 正規寫進 App Group（直接改 plist 檔 cfprefsd 不認）；沒帶就清掉。
        let key = "utuvo.type.keyboard.debugPose"
        if let pose = UserDefaults.standard.string(forKey: key) {
            KeyboardPresence.defaults.set(pose, forKey: key)
        } else {
            KeyboardPresence.defaults.removeObject(forKey: key)
        }
        #endif
    }

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
    }
}
