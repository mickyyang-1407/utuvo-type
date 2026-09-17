import Foundation
import UTUVOTypeCore

/// iOS 端文字管線：包 UTUVOTypeCore Normalizer（與 macOS 同一正本）。
/// 範圍：台灣用語詞級轉換（TaiwanPhrases，純 Swift 版的 s2twp 精簡表）、濾語助詞、自我修正、
/// 字典替換、數字正規化。台灣用語先套、字典後套，使用者字典永遠能覆寫。
struct TextPipeline: Sendable {
    private let normalizer: Normalizer

    init(dictionary: [String: String] = DictionaryStore.shared.dictionary) {
        self.normalizer = Normalizer(options: NormalizerOptions(
            dictionary: dictionary,
            fillerSet: NormalizerOptions.defaultFillers,
            localeIdentifier: "zh_TW"
        ))
    }

    /// 逐字稿 → 清理後輸出。回傳 (清理結果, 套用步驟)。
    func clean(_ transcript: String) -> (output: String, steps: [String]) {
        let localized = TaiwanPhrases.apply(transcript)
        let result = normalizer.normalize(localized)
        var steps = result.appliedSteps
        if localized != transcript { steps.insert("taiwan-phrases", at: 0) }
        return (result.cleaned, steps)
    }
}
