import Foundation

/// 鍵盤 ↔ 主 app 的語音橋接。
///
/// iOS 不讓第三方鍵盤開麥克風（AVAudioSession 在 extension 內 setActive 直接失敗，
/// 2026-09-17 實機：`com.apple.coreaudio.avfaudio`）。所以錄音與辨識由主 app 做：
///   1. 鍵盤第一次按光球 → 寫 start 指令 → 用 URL 叫起主 app。
///   2. 主 app 開麥克風、背景保持語音工作階段（UIBackgroundModes audio），照指令開始辨識。
///   3. 使用者點左上角回到原 app；鍵盤之後的開始／停止都走 Darwin notification，不再跳 app。
///   4. 逐字稿（partial／final）由主 app 寫進 App Group 的 state 檔，鍵盤收到通知去讀。
/// 橋接本身只走 App Group 容器（本機檔案）；選配 context 後續是否送到整理服務，由使用者開關控制。
enum VoiceBridge {
    static let groupID = "group.com.utuvo.type"
    static let urlScheme = "utuvotype"
    static let urlHost = "voice"
    /// 鍵盤左上品牌區：打開主 app 的「設定」分頁。
    static let settingsURL = URL(string: "\(urlScheme)://settings")!

    enum Note: String, Sendable {
        /// 鍵盤 → 主 app：command.json 有新指令。
        case command = "com.utuvo.type.voice.command"
        /// 主 app → 鍵盤：state.json 有更新。
        case update = "com.utuvo.type.voice.update"
        /// 鍵盤仍在使用：延長已開啟工作階段的閒置期限，不覆寫語音指令。
        case keyboardActivity = "com.utuvo.type.voice.keyboardActivity"
    }

    struct Command: Codable, Equatable, Sendable {
        enum Action: String, Codable, Sendable { case start, stop, cancel, endSession }
        var action: Action
        var id: UUID
        var language: String
        var sentAt: Date
        /// 長按翻譯時的目標語言代碼（TranslationTarget.code）；主 app 一開始錄就預熱翻譯。
        var translateTo: String? = nil
        /// Keyboard extension supplies a bounded, local-only field excerpt only when the user opted in.
        var contextText: String? = nil
    }

    struct State: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable { case ready, recording, finishing, failed, ended }
        var phase: Phase
        /// 主 app 每秒更新；鍵盤用它判斷工作階段還活著沒。
        var heartbeat: Date
        var commandID: UUID?
        var partial: String = ""
        var final: String?
        /// 主 app 已翻好的結果（有 translateTo 時）；nil＝鍵盤自己翻。
        var translated: String?
        /// 定稿先送（不等校正），背景整理完、真的有改才放進來（依指令 id，留最近幾筆）。
        /// 不跟著 commandID 走：使用者連講好幾段，前一段的更正回來時已經換成下一段的指令（2026-09-20 實機：前一段更正被丟掉）。
        var corrections: [Correction]?
        /// 正在背景整理的指令 id（鍵盤顯示「整理中…」）。
        var refining: [UUID]?

        struct Correction: Codable, Equatable, Sendable {
            var id: UUID
            var text: String
        }
        var error: String?
        /// "onDevice"／"server"
        var route: String?
        /// 閒置多久後自動關麥克風（顯示用）。
        var idleEndsAt: Date?
    }

    // MARK: - 純邏輯（可測）

    /// 心跳超過這個秒數沒更新＝主 app 已被系統收掉或工作階段已結束。
    static let liveWindow: TimeInterval = 3.5
    /// 指令超過這個秒數才被讀到＝過期（例如主 app 很久以後才被打開），不執行。
    static let commandTTL: TimeInterval = 30
    /// 按停止後主 app 等 final 的上限；逾時就拿最後的 partial 當 final。
    static let finalizeTimeout: TimeInterval = 3
    /// 預設閒置多久自動結束語音工作階段（3 分鐘）（關麥克風、橘點消失）。
    static let defaultIdleTimeout: TimeInterval = 3 * 60   // 2026-09-18 產品決定：5 分鐘太久
    static let extendedIdleTimeout: TimeInterval = 10 * 60
    /// 使用者自選「鍵盤語音保持開啟」分鐘數（2026-09-24：iOS 26.4 起沒有公開 API 能自動跳回原 App，
    /// 能做的是讓跳轉少發生——工作階段開著就不用再跳）。0＝沒設定＝預設 3 分鐘。
    static let sessionMinutesKey = "utuvo.type.ios.keyboardSessionMinutes"
    static let sessionMinuteChoices = [3, 10, 30, 60]
    static func userIdleTimeout(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let minutes = defaults.integer(forKey: sessionMinutesKey)
        return sessionMinuteChoices.contains(minutes) ? TimeInterval(minutes * 60) : defaultIdleTimeout
    }
    static let keyboardActivityInterval: TimeInterval = 45

    static func isAlive(_ state: State?, now: Date = Date()) -> Bool {
        guard let state, state.phase != .ended else { return false }
        let age = now.timeIntervalSince(state.heartbeat)
        return age >= -5 && age <= liveWindow
    }

    enum StartPlan: Equatable, Sendable {
        /// 工作階段活著：送 Darwin 指令，不跳 app。
        case sendCommand
        /// 沒有工作階段：寫指令後用 URL 叫起主 app。
        case openApp
    }

    static func startPlan(state: State?, now: Date = Date()) -> StartPlan {
        isAlive(state, now: now) ? .sendCommand : .openApp
    }

    /// 只在主 app 仍活著時通知，並節流鍵盤每鍵輸入的跨程序訊號。
    static func shouldPostKeyboardActivity(state: State?, lastPosted: Date, now: Date = Date()) -> Bool {
        isAlive(state, now: now) && now.timeIntervalSince(lastPosted) >= keyboardActivityInterval
    }

    static func isFresh(_ command: Command, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(command.sentAt)
        return age >= -5 && age <= commandTTL
    }

    /// 鍵盤收到 state 更新時該做什麼。只處理「我發出的那個指令」的結果。
    enum Delivery: Equatable, Sendable {
        case ignore
        case partial(String)
        case final(String, translated: String?)
        case failed(String)
    }

    static func delivery(for state: State, expecting id: UUID?) -> Delivery {
        guard let id, state.commandID == id else { return .ignore }
        // 錯誤要「黏著」：主 app 心跳會把 phase 蓋回 ready，但只要這個指令還沒有 final，錯誤就還沒交給鍵盤。
        if state.phase == .failed || (state.error != nil && state.final == nil) {
            return .failed(state.error ?? String(localized: "語音工作階段出錯"))
        }
        if let final = state.final { return .final(final, translated: state.translated) }
        switch state.phase {
        case .recording, .finishing: return .partial(state.partial)
        default: return .ignore
        }
    }

    static func shouldEndIdleSession(phase: State.Phase, lastActivity: Date, now: Date, timeout: TimeInterval) -> Bool {
        phase == .ready && now.timeIntervalSince(lastActivity) >= timeout
    }

    // MARK: - URL

    static func sessionURL(language: String, commandID: UUID, returnTo hostBundleID: String? = nil) -> URL {
        var comps = URLComponents()
        comps.scheme = urlScheme
        comps.host = urlHost
        comps.queryItems = [
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "id", value: commandID.uuidString),
        ]
        if let hostBundleID, isPlausibleBundleID(hostBundleID) {
            comps.queryItems?.append(URLQueryItem(name: "return", value: hostBundleID))
        }
        return comps.url!
    }

    static func parseSessionURL(_ url: URL) -> (language: String, commandID: UUID?, returnTo: String?)? {
        guard url.scheme == urlScheme, url.host == urlHost,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let lang = items.first(where: { $0.name == "lang" })?.value, !lang.isEmpty else { return nil }
        let id = items.first(where: { $0.name == "id" })?.value.flatMap(UUID.init(uuidString:))
        let back = items.first(where: { $0.name == "return" })?.value.flatMap { isPlausibleBundleID($0) ? $0 : nil }
        return (lang, id, back)
    }

    /// URL 是外部可觸發的：只接受長得像 bundle id 的字串（反向網域、英數點橫線），不接受任意字串。
    static func isPlausibleBundleID(_ s: String) -> Bool {
        guard s.count <= 155, s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" }
            && !s.contains("..")
    }

    // MARK: - IO（App Group 檔案＋Darwin notification）

    /// App Group 內 `Library/VoiceBridge/`（不放容器根目錄：devicectl 只能讀 Library／Documents／tmp，放這裡真機才撈得到除錯檔）。
    static var containerURL: URL? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let dir = root.appendingPathComponent("Library/VoiceBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write<T: Encodable>(_ value: T, name: String, in directory: URL? = nil) {
        guard let dir = directory ?? containerURL, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, name: String, in directory: URL? = nil) -> T? {
        guard let dir = directory ?? containerURL,
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static let commandFile = "voice-command.json"
    static let stateFile = "voice-state.json"

    static func readState() -> State? { read(State.self, name: stateFile) }
    static func writeState(_ state: State) { write(state, name: stateFile) }
    static func readCommand() -> Command? { read(Command.self, name: commandFile) }
    static func writeCommand(_ command: Command) { write(command, name: commandFile) }

    /// Field text is a one-shot hint. Remove it from the shared command file once the host has copied it to memory.
    static func clearCommandContext(for id: UUID, in directory: URL? = nil) {
        guard var command = read(Command.self, name: commandFile, in: directory), command.id == id,
              command.contextText != nil else { return }
        command.contextText = nil
        write(command, name: commandFile, in: directory)
    }

    static func post(_ note: Note) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(note.rawValue as CFString), nil, nil, true
        )
    }
}

/// Darwin notification 的最小觀察者（跨 process，無 payload）。handler 一律在主執行緒跑。
final class DarwinObserver: @unchecked Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ note: VoiceBridge.Note, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { me.handler() } }
            },
            note.rawValue as CFString, nil, .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }
}
