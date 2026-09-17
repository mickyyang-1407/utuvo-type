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
        isStarred: Bool = false
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
    }
}
