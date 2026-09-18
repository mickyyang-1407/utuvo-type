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
    @ObservedObject private var voiceHost = KeyboardVoiceHost.shared

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
        ZStack {
            tabs
            // 鍵盤語音工作階段期間，整個主 app 換成專用畫面（沒有麥克風按鈕可點）。
            if voiceHost.isActive || voiceHost.lastError != nil {
                KeyboardSessionScreen(host: voiceHost)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: voiceHost.isActive)
        // 鍵盤叫起主 app：utuvotype://voice?lang=…&id=…
        .onOpenURL { url in
            tab = 0
            voiceHost.handle(url: url)
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            DictateView()
                .tabItem { Label("聽寫", image: "OrbGlyph") }
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
