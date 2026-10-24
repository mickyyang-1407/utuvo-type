import Foundation

/// 聽寫語言的**變體**（Typeless 的 language variants）。
///
/// 變體**不換辨識模型**：辨識用的 locale 還是 `DictationLanguage` 本身。變體控制：
/// 1. 整理提示詞（`promptInstruction`：要模型用哪一地的用字拼寫寫出結果）。
/// 2. 最終文字清理與驗證（台灣用語只在台灣變體下套用）。
/// 3. 介面上的變體名稱（跟著介面語言走）。
///
/// 儲存在 App Group（`KeyboardPresence.defaults`）：鍵盤與主 app 共用同一份，跟 `hantInputKey` 同一個路徑。
enum LanguageVariant: String, CaseIterable, Sendable {
    case none
    case zhTW = "zh_tw"
    case zhHK = "zh_hk"
    case zhCN = "zh_cn"
    case enUS = "en_us"
    case enGB = "en_gb"

    /// 提示詞裡要求的用字習慣（照實寫，模型才知道要換什麼字）。沒有變體時回 nil（提示詞不加這一段）。
    var promptInstruction: String? {
        switch self {
        case .none: return nil
        case .zhTW:
            return String(localized: "語言變體與用字習慣要求：繁體中文（台灣用字與慣用詞，例：「軟體」「程式」「透過」「影片」；不要出現「的士」「巴士」等港式或簡體用字）。")
        case .zhHK:
            return String(localized: "語言變體與用字習慣要求：繁體中文（香港用字與慣用詞，例：「的士」「小巴」「雪櫃」「檔案」；不要出現台灣或大陸用字）。")
        case .zhCN:
            return String(localized: "語言變體與用字習慣要求：簡體中文（中國大陸用字與慣用詞，例：「软件」「程序」「视频」；不要出現繁體字形）。")
        case .enUS:
            return String(localized: "Language variant: American English. Use US spelling and vocabulary (e.g. \"color\", \"organize\", \"elevator\", \"apartment\").")
        case .enGB:
            return String(localized: "Language variant: British English. Use UK spelling and vocabulary (e.g. \"colour\", \"organise\", \"lift\", \"flat\").")
        }
    }

    func displayName(traditional: Bool) -> String {
        switch self {
        case .none: return traditional ? String(localized: "預設") : "Default"
        case .zhTW: return traditional ? String(localized: "台灣繁體") : "Traditional (Taiwan)"
        case .zhHK: return traditional ? String(localized: "香港繁體") : "Traditional (Hong Kong)"
        case .zhCN: return traditional ? String(localized: "簡體") : "Simplified"
        case .enUS: return traditional ? String(localized: "美式英文") : "American English"
        case .enGB: return traditional ? String(localized: "英式英文") : "British English"
        }
    }

    /// 這張工單（ios-C-repair1 第 5 點）的關鍵：**變體必須一路吃到後處理**。
    ///
    /// `TraditionalFixer` 走的是 OpenCC **s2tw**（簡→繁、**台灣用字**）＋台灣正式寫法覆寫，
    /// 所以它只能用在「要台灣繁體」的輸出上。變體選香港或簡體時再套它，就是**用後處理把模型
    /// 照變體寫出來的字改回去**（工單說的「強制轉回台灣繁體」）。
    ///
    /// 查證結果（10-14 實測字典）：`Shared/Resources/OpenCC` 只有一組 s2tw 字典，**沒有 s2hk**。
    /// 香港特有用字（的士／小巴／雪櫃／士多／便利店／捷運／地鐵）在字典裡**一筆都沒有**，
    /// 所以香港用字不會被逐詞改寫；但 s2tw 會把**共用字形**往台灣靠（例：臺→台、瞭解→了解、
    /// 儘量→盡量、絃→弦 這四筆 `everyday` 覆寫無條件生效），字形層面仍然是台灣的。
    /// 結論：**香港與簡體變體一律不套 `TraditionalFixer`**，只有台灣繁體才套。
    ///
    /// - `.none`：沿用舊行為（由 `language` 是不是 zh-TW 決定）——不變更既有結果。
    var appliesTaiwanTraditionalFixer: Bool? {
        switch self {
        case .none: return nil          // 沒選變體 → 交給呼叫端用舊規則判
        case .zhTW: return true         // 台灣繁體 → s2tw 正是要的
        case .zhHK: return false        // 香港用字：字典會把共用字形拉回台灣，會改掉變體要求的字
        case .zhCN: return false        // 簡體：s2tw 會把簡體全部轉成繁體
        case .enUS, .enGB: return false // 英文沒有繁簡問題，不該被中文轉換器碰
        }
    }

    /// 這張工單要求變體「一路吃到後處理」，所以 `traditional` 這個旗標要從變體推導，
    /// 不能只看 `language.hasPrefix("zh-TW")`。回 nil 代表「沒有變體資訊，照舊」。
    static func traditionalFixerTarget(variant: LanguageVariant, language: String) -> Bool {
        variant.appliesTaiwanTraditionalFixer ?? language.hasPrefix("zh-TW")
    }
}

extension DictationLanguage {
    /// 這個語言可以選的變體（沒有變體的語言回空陣列，設定頁就不顯示那一列）。
    /// 順序＝預設永遠在第一個。
    var variants: [LanguageVariant] {
        switch self {
        case .traditionalChinese: return [.zhTW, .zhHK, .zhCN]
        case .simplifiedChinese: return [.zhCN, .zhTW, .zhHK]
        case .englishUS: return [.enUS, .enGB]
        case .japanese, .korean: return []
        }
    }

    /// 預設變體＝**現狀**（不選時的行為跟這張工單之前完全一樣）。
    var defaultVariant: LanguageVariant {
        variants.first ?? .none
    }

    /// 讀不到、認不出就回預設（不要因為存了壞值就整個提示詞失效）。
    func resolveVariant(_ raw: String?) -> LanguageVariant {
        guard let raw, let value = LanguageVariant(rawValue: raw) else { return defaultVariant }
        return variants.contains(value) ? value : defaultVariant
    }
}

/// 每種聽寫語言目前的變體選擇（App Group，鍵盤與主 app 共用）。
enum LanguageVariantStore {
    private static let prefix = "utuvo.type.dictationVariant."

    static func key(for language: DictationLanguage) -> String { prefix + language.rawValue }

    public static func variant(for language: DictationLanguage,
                               in defaults: UserDefaults = KeyboardPresence.defaults) -> LanguageVariant {
        language.resolveVariant(defaults.string(forKey: key(for: language)))
    }

    public static func setVariant(_ variant: LanguageVariant, for language: DictationLanguage,
                                  in defaults: UserDefaults = KeyboardPresence.defaults) {
        guard language.variants.contains(variant) else { return }
        defaults.set(variant.rawValue, forKey: key(for: language))
    }

    /// 使用者現在在聽寫的那個語言的變體（提示詞組裝用）。
    public static func currentVariant(language: String, in defaults: UserDefaults = KeyboardPresence.defaults) -> LanguageVariant {
        guard let lang = DictationLanguage(rawValue: language) else { return .none }
        return variant(for: lang, in: defaults)
    }
}
