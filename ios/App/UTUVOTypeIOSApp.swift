import SwiftUI
import UTUVOTypeCore

@main
struct UTUVOTypeIOSApp: App {
    init() {
        TipJar.startListening()
        // 沒有 Apple Intelligence 的 iPhone：手機上的 Gemma 整理（下載過才會用）。
        GemmaCleanup.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    /// App 內選的外觀（跟隨系統／淺色／深色；工單 ios-C 第 2 點）。
    /// 鍵盤 extension 讀同一個 App Group 值，這樣兩邊的外觀一定一致。
    @AppStorage(AppearanceStore.settingKey, store: AppearanceStore.defaults)
    private var appearance: AppearancePreference = .system
    /// 截圖用 DEBUG 開關：`-utuvo.type.ios.debugTab 0|1|2` 直接開在聽寫／歷史／設定分頁
    ///（模擬器沒麥克風、也沒辦法點觸控時，沒這個就截不到另外兩頁）。
    @State private var tab = RootView.debugInitialTab()
    private static func debugInitialTab() -> Int {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "utuvo.type.ios.debugTab"), let n = Int(raw) {
            return min(max(n, 0), 2)
        }
        #endif
        return 0
    }
    @ObservedObject private var voiceHost = KeyboardVoiceHost.shared
    @Environment(\.scenePhase) private var scenePhase

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
        // UI 測試：`-utuvo.type.debug.noOnDeviceAI YES` 當作沒有 Apple Intelligence，走退路／錯誤說明。
        // 09-30 起 macOS／iOS 27.0 的 Apple Intelligence 恢復可用，測試不能再靠「它一定壞」。
        KeyboardPresence.defaults.set(UserDefaults.standard.bool(forKey: OnDeviceAssistant.debugDisableKey),
                                      forKey: OnDeviceAssistant.debugDisableKey)
        // UI 測試：`-utuvo.type.debug.swallowOpenApp YES` 模擬系統默默不理鍵盤的「開啟主 app」（10-05 17PMX iOS 27.0.1）。
        KeyboardPresence.defaults.set(UserDefaults.standard.bool(forKey: "utuvo.type.debug.swallowOpenApp"),
                                      forKey: "utuvo.type.debug.swallowOpenApp")
        // App Store 截圖：`-utuvo.type.keyboard.language zh-CN` 指定鍵盤聽寫語言（徽章顯示「简中」）。
        if let lang = UserDefaults.standard.string(forKey: "utuvo.type.keyboard.language") {
            KeyboardPresence.defaults.set(lang, forKey: "utuvo.type.keyboard.language")
        }
        // App Store 截圖：`-utuvo.type.ios.seedHistory YES` 在歷史是空的時候種幾筆範例（模擬器沒麥克風）。
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.seedHistory"), HistoryStore.shared.load().isEmpty {
            let now = Date()
            let hans = Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true
            let samples: [(String, DictationRecord.Source, Double, Bool)] = hans ? [
                ("明天下午三点在录音室对 Atmos 母带，记得带硬盘和耳机。", .keyboard, -600, true),
                ("好，那我们周五前把混音版本发给客户，周一再确认一次。", .keyboard, -3_600, false),
                ("Can we move the session to Thursday? The drummer is only free after four.", .app, -7_200, false),
                ("今天的课讲到空间音频的交付规范，下周请大家带自己的作品来听。", .app, -86_400, true),
                ("晚饭想吃什么？我这边大概七点半结束。", .keyboard, -90_000, false),
                ("母带的整体响度控制在 −18 LUFS 左右，真峰值不要超过 −1 dBTP。", .app, -180_000, false),
            ] : [
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
        // App Store／工單截圖用：`-utuvo.type.ios.seedUsage YES` 在每日計數是空的時候種幾週的假用量，
        // 讓首頁的使用數據卡、熱圖與連續天數有東西可以截（模擬器沒麥克風，錄不出真資料）。
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.seedUsage"), DailyUsageStore.shared.load().isEmpty {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            var seeded: [DailyUsage] = []
            for dayOffset in 0..<70 {
                guard let d = cal.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
                // 最近兩週每天都有用量（看得到連續天數），更早的稀疏一點（看得到熱圖階色）。
                let dense = dayOffset < 14
                guard dense || dayOffset % 3 == 0 else { continue }
                let words = dense ? 180 + (dayOffset * 37) % 900 : 60 + (dayOffset * 53) % 400
                seeded.append(DailyUsage(day: UsageDay.string(from: d, calendar: cal),
                                         words: words,
                                         seconds: Double(words) / 3.4,
                                         sessions: 3 + dayOffset % 5))
            }
            DailyUsageStore.shared.seed(seeded)
        }
        // 截圖用：`-utuvo.type.ios.seedDictionary YES` 種幾個詞（含 CorrectionLearner 學來的），
        // 讓字典分頁看得到「自動」標記。直接在 App Group 外面改 plist 沒用（cfprefsd 不認）。
        if UserDefaults.standard.bool(forKey: "utuvo.type.ios.seedDictionary") {
            DictionaryStore.shared.addTerm(source: "Atmos", output: "")
            DictionaryStore.shared.addTerm(source: "Tonmeister", output: "")
            DictionaryStore.shared.addTerm(source: "pik", output: "Pik")
            for (wrong, right) in [("除值", "儲值"), ("及時", "即時")] {
                DictionaryStore.shared.addTerm(source: wrong, output: right)
                LearnedVocabulary.markAutoLearned(wrong)
            }
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
        // App 內選的外觀（nil = 跟隨系統）。這個值放在最外層，鍵盤與主 app 才會一致。
        .preferredColorScheme(appearance.colorScheme)
        // 點擊震動：每個按鈕／選項／自己點的分頁都震一下（介面震動開關可關）。
        .tapPulseFeedback()
        // 個人字典 iPhone↔Mac（iCloud）：每次回到前景同步一次；外部變更有通知。
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { DictionaryCloud.start() }
        }
        // 鍵盤叫起主 app：utuvotype://voice?lang=…&id=…
        // 鍵盤左上品牌區：utuvotype://settings → 設定分頁。
        .onOpenURL { url in
            if url == VoiceBridge.settingsURL { tab = 2; return }
            tab = 0
            voiceHost.handle(url: url)
        }
    }

    private var tabs: some View {
        // 自己點下面的分頁才震；程式切分頁（鍵盤叫起 App、開設定網址）直接改 tab，不經這裡、不震。
        TabView(selection: Binding(get: { tab }, set: { newTab in
            if newTab != tab { TapPulse.shared.fire() }
            tab = newTab
        })) {
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
        .uiFeedbackProbe()
    }
}
