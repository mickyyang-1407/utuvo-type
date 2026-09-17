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
        case .traditionalChinese: return zh ? "繁體中文" : "Traditional Chinese"
        case .simplifiedChinese: return zh ? "簡體中文" : "Simplified Chinese"
        case .englishUS: return zh ? "英文（美國）" : "English (US)"
        case .japanese: return zh ? "日文" : "Japanese"
        case .korean: return zh ? "韓文" : "Korean"
        }
    }
}
