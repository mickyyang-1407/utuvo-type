import Foundation

/// 聽寫語言（iOS v1：Apple Speech 支援的子集）。
enum DictationLanguage: String, CaseIterable, Identifiable, Sendable {
    case traditionalChinese = "zh-TW"
    case simplifiedChinese = "zh-CN"
    case englishUS = "en-US"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var id: String { rawValue }

    func localizedName(zh: Bool) -> String {
        switch self {
        case .traditionalChinese: return zh ? String(localized: "繁體中文") : "Traditional Chinese"
        case .simplifiedChinese: return zh ? String(localized: "簡體中文") : "Simplified Chinese"
        case .englishUS: return zh ? String(localized: "英文（美國）") : "English (US)"
        case .japanese: return zh ? String(localized: "日文") : "Japanese"
        case .korean: return zh ? String(localized: "韓文") : "Korean"
        }
    }
}

extension DictationLanguage {
    /// 徽章／選單用的短名（鍵盤右上語言徽章、主 app 語言選單）。「繁中」「简中」是在講文字系統，不是介面語言——
    /// 兩種介面都一樣，刻意不在地化（UI 測試也拿「繁中」當認鍵盤的把手）。
    var shortLabel: String {
        switch self {
        case .traditionalChinese: return "繁中"
        case .simplifiedChinese: return "简中"
        case .englishUS: return "EN"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}
