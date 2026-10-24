import Foundation

/// modes-v2（2026-10-22）：錄音時圓球下方的小標籤，講清楚「這一段是什麼模式、要翻成什麼」。
/// 一般聽寫不顯示（nil），圓球維持原本 96×96。
/// 優先順序：Ask anything → 翻譯目標 → Edit Selection。
enum OverlayBadge {
    static func text(translation: TranslationTarget, ask: Bool, editSelection: Bool, zh: Bool) -> String? {
        if ask { return "Ask anything" }
        if translation != .off { return "→ " + translation.endonym }
        if editSelection { return zh ? "改寫選取" : "Edit Selection" }
        return nil
    }
}

extension TranslationTarget {
    /// 語言的自稱（標籤用；不跟介面語言走，使用者一眼認得出目標語言）。
    var endonym: String {
        switch self {
        case .off: return ""
        case .english: return "English"
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .russian: return "Русский"
        case .thai: return "ไทย"
        case .vietnamese: return "Tiếng Việt"
        case .indonesian: return "Bahasa Indonesia"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .dutch: return "Nederlands"
        }
    }
}
