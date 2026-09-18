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
        // App Store 截圖：`-utuvo.type.ios.seedHistory YES` 在歷史是空的時候種幾筆範例（模擬器沒麥克風）。
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.seedHistory"), HistoryStore.shared.load().isEmpty {
            let now = Date()
            let samples: [(String, DictationRecord.Source, Double, Bool)] = [
                ("明天下午三點在錄音室對 Atmos 母帶，記得帶硬碟和耳機。", .keyboard, -600, true),
                ("好，那我們週五前把混音版本寄給客戶，週一再確認一次。", .keyboard, -3_600, false),
                ("Can we move the session to Thursday? The drummer is only free after four.", .app, -7_200, false),
                ("今天的課講到空間音訊的交付規範，下週請大家帶自己的作品來聽。", .app, -86_400, true),
                ("晚餐想吃什麼？我這邊大概七點半會結束。", .keyboard, -90_000, false),
                ("母帶的整體響度控制在 −18 LUFS 左右，真峰值不要超過 −1 dBTP。", .app, -180_000, false),
            ]
            let records = samples.map { text, source, offset, starred in
                DictationRecord(date: now.addingTimeInterval(offset), raw: text, cleaned: text, starred: starred, source: source)
            }
            HistoryStore.shared.save(records.sorted { $0.date > $1.date })
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
