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
        text = WhisperHallucination.normalizeSmallFormPunctuation(text)
        if language.hasPrefix("zh-TW") || language.hasPrefix("zh-Hant") || language.hasPrefix("zh-HK") {
            text = text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
            text = TraditionalFixer.shared.fix(TaiwanPhrases.apply(text))
        }
        return text
    }

    /// 本體在 `WhisperHallucination`（UTUVOTypeCore，Mac 共用；2026-10-19 原封不動搬去）。
    nonisolated static var outroPhrases: [String] { WhisperHallucination.outroPhrases }

    nonisolated static func dropOutroHallucination(_ text: String, reference: String? = nil) -> String {
        WhisperHallucination.dropOutro(text, reference: reference)
    }

    /// 解碼迴圈：本體在 `WhisperHallucination.looksLooping`。
    nonisolated static func looksLooping(_ text: String, seconds: Double) -> Bool {
        WhisperHallucination.looksLooping(text, seconds: seconds)
    }
}
