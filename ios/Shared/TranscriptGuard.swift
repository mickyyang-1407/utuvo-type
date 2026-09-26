import Foundation
import UTUVOTypeCore

/// 重辨識（本機 Qwen、雲端）拿回來的整段文字共用的整理與把關。純函式、不碰 UIKit／MLX，
/// 所以 Mac 量測工具（Benchmarks/KeyboardChainBench）也編得進去。原本在 `LocalQwenASR`，2026-09-25 原封不動搬來。
enum TranscriptGuard {
    /// 繁中：Qwen 有時輸出簡體（實機「麻烦你把…」）→ ICU 簡轉繁 → 台灣用語 → 修逐字硬轉（迴家→回家）。
    nonisolated static func clean(_ raw: String, language: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Groq Whisper 的中文常輸出 Unicode「小寫」標點（﹐ U+FE50 等，2026-09-25 實測 128 段裡 13 段有）；
        // 後面的自我更正（「不對」）與贅字規則只認一般全形標點，不轉會把「禮拜三﹐不對﹐禮拜四」切成「﹐禮拜四」。
        text = String(text.map { smallFormPunctuation[$0] ?? $0 })
        if language.hasPrefix("zh-TW") || language.hasPrefix("zh-Hant") || language.hasPrefix("zh-HK") {
            text = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
            text = TraditionalFixer.shared.fix(TaiwanPhrases.apply(text))
        }
        return text
    }

    /// Unicode Small Form Variants（U+FE50–FE57）→ 一般全形標點。
    private static let smallFormPunctuation: [Character: Character] = [
        "\u{FE50}": "，", "\u{FE51}": "、", "\u{FE52}": "。", "\u{FE54}": "；",
        "\u{FE55}": "：", "\u{FE56}": "？", "\u{FE57}": "！",
    ]

    /// 解碼迴圈（Mac 60 段實測：熱詞偶爾讓模型卡在「T O T O …」）：同一個 1–8 字單位連續 8 次以上，
    /// 或字數遠超過人能講的量（每秒 12 字）。
    nonisolated static func looksLooping(_ text: String, seconds: Double) -> Bool {
        if text.count > max(80, Int(seconds * 12)) { return true }
        return text.range(of: #"(.{1,8}?)(?:\s*\1){7,}"#, options: .regularExpression) != nil
    }
}
