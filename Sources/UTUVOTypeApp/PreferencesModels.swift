import Foundation
import UTUVOTypeCore

// 「二次元」選項已依產品決定移除（2026-08-21）；舊儲存值 "retro" 由
// AppPreferences 讀取時 fallback 成 .system，rawValue key 不變。
enum AppThemeChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    func localizedName(zh: Bool) -> String {
        switch self {
        case .system: return zh ? "跟隨系統" : "System"
        case .light: return zh ? "亮色" : "Light"
        case .dark: return zh ? "深色" : "Dark"
        }
    }
}

/// 中文輸出字形：本機 wrapper 以 OpenCC 轉換；rawValue 直接經環境變數傳給 wrapper。
enum OutputScript: String, CaseIterable, Codable, Identifiable, Sendable {
    case traditional
    case simplified
    case asIs = "as-is"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .traditional: return "繁體中文（台灣）"
        case .simplified: return "簡體中文"
        case .asIs: return "模型原樣"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .traditional: return zh ? "繁體中文（台灣）" : "Traditional Chinese (Taiwan)"
        case .simplified: return zh ? "簡體中文" : "Simplified Chinese"
        case .asIs: return zh ? "模型原樣" : "As transcribed"
        }
    }
}

/// 翻譯輸出：聽寫完成後由本機小型 editor 翻成目標語言再貼上。
enum TranslationTarget: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case russian = "ru"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case arabic = "ar"
    case hindi = "hi"
    case dutch = "nl"

    var id: String { rawValue }

    /// 塞進翻譯 prompt 的語言名稱（給模型看，固定英文）。
    var promptName: String {
        switch self {
        case .off: return ""
        case .english: return "English"
        case .traditionalChinese: return "Traditional Chinese (Taiwan)"
        case .simplifiedChinese: return "Simplified Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .dutch: return "Dutch"
        }
    }

    func localizedName(zh: Bool) -> String {
        switch self {
        case .off: return zh ? "關閉（原文輸出）" : "Off (original text)"
        case .english: return zh ? "英文" : "English"
        case .traditionalChinese: return zh ? "繁體中文" : "Traditional Chinese"
        case .simplifiedChinese: return zh ? "簡體中文" : "Simplified Chinese"
        case .japanese: return zh ? "日文" : "Japanese"
        case .korean: return zh ? "韓文" : "Korean"
        case .french: return zh ? "法文" : "French"
        case .german: return zh ? "德文" : "German"
        case .spanish: return zh ? "西班牙文" : "Spanish"
        case .italian: return zh ? "義大利文" : "Italian"
        case .portuguese: return zh ? "葡萄牙文" : "Portuguese"
        case .russian: return zh ? "俄文" : "Russian"
        case .thai: return zh ? "泰文" : "Thai"
        case .vietnamese: return zh ? "越南文" : "Vietnamese"
        case .indonesian: return zh ? "印尼文" : "Indonesian"
        case .arabic: return zh ? "阿拉伯文" : "Arabic"
        case .hindi: return zh ? "印地文" : "Hindi"
        case .dutch: return zh ? "荷蘭文" : "Dutch"
        }
    }
}

enum OverlayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case live
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return "Live"
        case .off: return "Off"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .live: return zh ? "顯示" : "Live"
        case .off: return zh ? "關閉" : "Off"
        }
    }
}

enum OverlayPosition: String, CaseIterable, Codable, Identifiable, Sendable {
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .top: return zh ? "螢幕上方" : "Top"
        case .bottom: return zh ? "螢幕下方" : "Bottom"
        }
    }
}

enum UnloadPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case never
    case afterFiveMinutes
    case afterFifteenMinutes
    case afterOneHour

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .afterFiveMinutes: return "After 5 minutes"
        case .afterFifteenMinutes: return "After 15 minutes"
        case .afterOneHour: return "After 1 hour"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .never: return zh ? "永不" : "Never"
        case .afterFiveMinutes: return zh ? "5 分鐘後" : "After 5 minutes"
        case .afterFifteenMinutes: return zh ? "15 分鐘後" : "After 15 minutes"
        case .afterOneHour: return zh ? "1 小時後" : "After 1 hour"
        }
    }
}

enum ClipboardHandling: String, CaseIterable, Codable, Identifiable, Sendable {
    case restore
    case keep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .restore: return "Restore previous clipboard"
        case .keep: return "Keep pasted text"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .restore: return zh ? "還原先前剪貼簿" : "Restore previous clipboard"
        case .keep: return zh ? "保留貼上的文字" : "Keep pasted text"
        }
    }
}

enum PasteMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case clipboard
    case accessibility

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clipboard: return "Clipboard (Command + V)"
        case .accessibility: return "Accessibility direct (fallback to Clipboard)"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .clipboard: return zh ? "剪貼簿（⌘V）" : "Clipboard (Command + V)"
        case .accessibility: return zh ? "輔助使用直插（退回剪貼簿）" : "Accessibility (direct)"
        }
    }
}

enum AutoSubmit: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case returnKey
    case commandReturn
    case controlReturn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .returnKey: return "Return"
        case .commandReturn: return "Command + Return"
        case .controlReturn: return "Control + Return"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .off: return zh ? "關閉" : "Off"
        case .returnKey: return "Return"
        case .commandReturn: return "Command + Return"
        case .controlReturn: return "Control + Return"
        }
    }
}

enum AutoDeletePolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case keepAll
    case latestLimit
    case afterOneDay
    case afterOneWeek
    case afterOneMonth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepAll: return "Keep all"
        case .latestLimit: return "Keep latest limit"
        case .afterOneDay: return "After 1 day"
        case .afterOneWeek: return "After 1 week"
        case .afterOneMonth: return "After 1 month"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .keepAll: return zh ? "全部保留" : "Keep all"
        case .latestLimit: return zh ? "只留最新上限" : "Keep latest limit"
        case .afterOneDay: return zh ? "1 天後刪除" : "After 1 day"
        case .afterOneWeek: return zh ? "1 週後刪除" : "After 1 week"
        case .afterOneMonth: return zh ? "1 個月後刪除" : "After 1 month"
        }
    }
}

enum AppLanguageChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case traditionalChinese
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
    func localizedName(zh: Bool) -> String {
        switch self {
        case .system: return zh ? "跟隨系統" : "System"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
}

struct AppPreset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var promptHint: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        promptHint: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.promptHint = promptHint
        self.enabled = enabled
    }
}

/// 這筆聽寫沒有完成的狀態（delivery-learning-1／app-shell-3，2026-10-22）。紀錄上 nil＝正常完成；
/// 舊紀錄沒有這欄＝nil。失敗與取消的紀錄不算使用數據，錄音留著可以重試。
enum HistoryStatus: String, Codable, Hashable, Sendable {
    /// 有錄到聲音但辨識沒有出字（斷網、key 錯、引擎壞了）：沒有逐字稿，錄音留著重新辨識。
    case failed
    /// 按了停止、還在處理時取消：沒有貼上；逐字稿（有的話）和錄音留著，可以重試。
    case cancelled
}

struct HistoryRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var rawTranscript: String
    var output: String
    var duration: TimeInterval
    var mode: FormatterMode
    var appName: String?
    var bundleIdentifier: String?
    var audioPath: String?
    var isStarred: Bool
    /// 這筆沒有照正常路徑完成時的原因（例如智慧整理逾時、改用剪貼簿貼上）。舊紀錄沒有這欄＝nil。
    var note: String?
    /// nil＝正常完成；`.failed`／`.cancelled` 見 `HistoryStatus`。舊紀錄沒有這欄＝nil。
    var status: HistoryStatus?
    /// 這段聽寫要翻成的語言（FX-4）：重試照這個再翻一次。nil＝沒翻譯；舊紀錄沒有這欄＝nil。
    var translation: TranslationTarget?

    /// 紀錄要存的翻譯目標（FX-4）：關閉＝nil（寫回去不帶這欄）。Edit Selection 的紀錄不能從歷史重試，照舊不存。
    static func storedTranslation(_ target: TranslationTarget, mode: FormatterMode) -> TranslationTarget? {
        target == .off || mode == .editSelection ? nil : target
    }

    /// Ask anything 的紀錄用這個 note 標記（中英介面同一個字串）。
    static let askAnythingNote = "Ask anything"
    /// Ask anything 的紀錄：逐字稿是指令、輸出是回答，不是聽寫（不能重試，app-shell-v1）。
    var isAskAnything: Bool { note == Self.askAnythingNote }

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        rawTranscript: String,
        output: String,
        duration: TimeInterval,
        mode: FormatterMode,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        audioPath: String? = nil,
        isStarred: Bool = false,
        note: String? = nil,
        status: HistoryStatus? = nil,
        translation: TranslationTarget? = nil
    ) {
        self.id = id
        self.date = date
        self.rawTranscript = rawTranscript
        self.output = output
        self.duration = duration
        self.mode = mode
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.audioPath = audioPath
        self.isStarred = isStarred
        self.note = note
        self.status = status
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, rawTranscript, output, duration, mode, appName, bundleIdentifier, audioPath, isStarred, note, status
        case translation
    }

    /// 跟自動產生的解碼一樣，只有 `status`／`translation` 寬鬆：舊紀錄沒有這欄、或是之後版本寫了這版不認得的值，都當 nil。
    /// 整份歷史是一個陣列一起解，一筆解不開就全部讀不出來（app-shell-1 risk）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        rawTranscript = try c.decode(String.self, forKey: .rawTranscript)
        output = try c.decode(String.self, forKey: .output)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        mode = try c.decode(FormatterMode.self, forKey: .mode)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        isStarred = try c.decode(Bool.self, forKey: .isStarred)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(HistoryStatus.init(rawValue:)) }
        translation = (try? c.decodeIfPresent(String.self, forKey: .translation))
            .flatMap { $0.flatMap(TranslationTarget.init(rawValue:)) }
    }

    /// 只有錄音、沒有逐字稿（辨識失敗或轉錄前就取消）：錄音是這段話唯一的一份。
    var isAudioOnly: Bool { rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 不忙的時候從歷史按「重試」有沒有東西可以跑（跟 `AppModel.retryHistory` 同一個 `RetryPolicy` 決策）。
    /// Edit Selection（要重新選取原文字）與 Ask anything 的紀錄不行；沒逐字稿又沒錄音的也不行。
    func isRetryable(hasAudio: Bool) -> Bool {
        switch RetryPolicy.decide(mode: mode, isRecording: false, isProcessing: false, isAskAnything: isAskAnything,
                                  rawTranscript: rawTranscript, hasAudio: hasAudio) {
        case .reformatFromRawTranscript, .retranscribeFromAudio: return true
        case .ignoreBusy, .needsReselection, .notDictation, .nothingToRetry: return false
        }
    }

    /// 還沒重試、有錄音、可以重新辨識的「辨識失敗」紀錄（repair-batch1）：保留規則不刪它、也不刪它的錄音——
    /// 錄音是那段話唯一的一份。重試成功（狀態清掉）後照一般規則；不能重試的（Edit Selection）沒有這個例外。
    /// 這裡只看路徑；錄音檔是不是真的還在由 `HistoryRetention.plan` 檢查（被外部刪掉的照一般文字規則，repair round 2）。
    var holdsRetryableAudio: Bool {
        status == .failed && audioPath != nil && isRetryable(hasAudio: true)
    }

    /// 設定頁的「重試」按鈕能不能按。正常完成的紀錄規則不變（Ask anything、錄音已刪的只有錄音紀錄不能按）；
    /// 失敗／取消的紀錄另外看這個模式能不能從歷史重試（Edit Selection 不行，repair-batch1）。
    func retryAvailable(audioExists: Bool) -> Bool {
        if isAskAnything || (isAudioOnly && !audioExists) { return false }
        guard status != nil else { return true }
        return isRetryable(hasAudio: audioExists)
    }
}

extension CleanupVariant {
    /// 設定頁顯示名稱（app-shell-7）。
    func displayName(zh: Bool) -> String {
        switch self {
        case .none: return zh ? "預設" : "Default"
        case .zhTW: return zh ? "台灣繁體" : "Traditional (Taiwan)"
        case .zhHK: return zh ? "香港繁體" : "Traditional (Hong Kong)"
        case .zhCN: return zh ? "簡體（中國大陸）" : "Simplified (Mainland China)"
        case .enUS: return zh ? "美式英文" : "American English"
        case .enGB: return zh ? "英式英文" : "British English"
        }
    }
}
