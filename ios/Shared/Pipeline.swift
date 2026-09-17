import Foundation
import UTUVOTypeCore

/// iOS 端文字管線：包 UTUVOTypeCore Normalizer（與 macOS 同一正本）。
/// v1 範圍：濾語助詞、自我修正、字典替換、數字正規化。
/// 不做：繁台 OpenCC 轉換（iOS 無乾淨綁定，v2 再議）、雲端 editor（Fast 對齊）。
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
        let result = normalizer.normalize(transcript)
        return (result.cleaned, result.appliedSteps)
    }
}
