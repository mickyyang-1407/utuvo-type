import Foundation

/// Mac 聽寫語言的「變體」（app-shell-7，2026-10-22；對齊 iOS `LanguageVariant`／Typeless language variants）。
///
/// 變體不換辨識模型，只在整理提示詞**後面多接一行**用字習慣要求。`.none`＝什麼都不加，
/// 預設提示詞一個 byte 都不變（`CleanupVariantTests` 釘住）。
///
/// 要求句是固定字串常數（不走 `String(localized:)`）：提示詞是送給模型的，不能跟著介面語言或翻譯檔變。
/// 字句跟 iOS `ios/Shared/LanguageVariant.swift` 逐字相同，`CleanupVariantTests` 讀 iOS 原始檔比對。
/// 型別名刻意不叫 `LanguageVariant`，免得 iOS（同時連結 UTUVOTypeCore）那邊的同名型別被遮住。
public enum CleanupVariant: String, CaseIterable, Codable, Sendable {
    case none
    case zhTW = "zh_tw"
    case zhHK = "zh_hk"
    case zhCN = "zh_cn"
    case enUS = "en_us"
    case enGB = "en_gb"

    public static let zhTWInstruction =
        "語言變體與用字習慣要求：繁體中文（台灣用字與慣用詞，例：「軟體」「程式」「透過」「影片」；不要出現「的士」「巴士」等港式或簡體用字）。"
    public static let zhHKInstruction =
        "語言變體與用字習慣要求：繁體中文（香港用字與慣用詞，例：「的士」「小巴」「雪櫃」「檔案」；不要出現台灣或大陸用字）。"
    public static let zhCNInstruction =
        "語言變體與用字習慣要求：簡體中文（中國大陸用字與慣用詞，例：「软件」「程序」「视频」；不要出現繁體字形）。"
    public static let enUSInstruction =
        "Language variant: American English. Use US spelling and vocabulary (e.g. \"color\", \"organize\", \"elevator\", \"apartment\")."
    public static let enGBInstruction =
        "Language variant: British English. Use UK spelling and vocabulary (e.g. \"colour\", \"organise\", \"lift\", \"flat\")."

    /// 提示詞要接的那一行；`.none` 回 nil（不接）。
    public var promptInstruction: String? {
        switch self {
        case .none: return nil
        case .zhTW: return Self.zhTWInstruction
        case .zhHK: return Self.zhHKInstruction
        case .zhCN: return Self.zhCNInstruction
        case .enUS: return Self.enUSInstruction
        case .enGB: return Self.enGBInstruction
        }
    }

    /// 接在系統提示後面的區塊（"\n" ＋ 要求句）；`.none` 是空字串。
    public var promptBlock: String {
        promptInstruction.map { "\n" + $0 } ?? ""
    }

    /// 這個聽寫語言（Mac 的 `TranscriptionLanguage.rawValue`）可以選的變體；`.none` 永遠在第一個。
    /// 沒有變體的語言回空陣列（設定頁就不顯示那一列）。
    public static func options(forLanguage language: String) -> [CleanupVariant] {
        switch language {
        case "zh-TW": return [.none, .zhTW, .zhHK, .zhCN]
        case "en-US": return [.none, .enUS, .enGB]
        default: return []
        }
    }

    /// 中文變體對應的輸出字形（Mac 的 `OutputScript.rawValue`）：台灣／香港＝繁體、中國大陸＝簡體；其他回 nil（不動）。
    public var outputScriptRawValue: String? {
        switch self {
        case .zhTW, .zhHK: return "traditional"
        case .zhCN: return "simplified"
        case .none, .enUS, .enGB: return nil
        }
    }

    /// 真正要用的變體：選的變體不屬於目前語言，或跟目前輸出字形對不上（例如選了簡體變體、輸出字形又改回繁體），
    /// 一律當 `.none`——提示詞要求的字形不能跟後處理打架。
    public static func effective(_ stored: CleanupVariant, language: String, outputScript: String) -> CleanupVariant {
        guard stored != .none, options(forLanguage: language).contains(stored) else { return .none }
        if let script = stored.outputScriptRawValue, script != outputScript { return .none }
        return stored
    }

    /// 香港繁體：要繁體字形，但不套台灣用字修正（s2tw 字典與台灣慣用寫法會把港式用字改掉）。
    public var appliesTaiwanFixes: Bool { self != .zhHK }
}
