import Foundation
import UTUVOTypeCore

/// Mac 語音翻譯的路線（modes-1，2026-10-22）。
///
/// 以前只有一條：本機小型 editor（Qwen3-4B）。安裝程式從來不下載那個模型，新裝的 Mac 按 ⇧ 翻譯
/// 只會貼出原文加一句「翻譯未完成」；使用者在設定填好的 Claude／Groq key 完全沒被用到。
/// 現在照 iOS／Android：先照聽寫一樣整理（同一道忠實度把關），再用三個平台同一句提示詞
/// （`TranslatePrompt`）翻譯；譯文本來就跟原文不像，不再過整理把關。
enum DictationTranslation {
    enum Engine: String, Equatable, Sendable {
        /// 使用者自己的整理服務 key：整理 → 翻譯兩步。
        case cloud
        /// macOS 26 系統翻譯（裝置端、語言包已裝才用）。
        case system
        /// 本機小型 editor（真的裝了模型、或使用者自己設定了別的 command）。
        case localEditor
    }

    /// 依序嘗試的翻譯方法。
    /// - cloud：智慧整理有開**而且**有 key。智慧整理預設關（AppPreferences），只有 key 不算同意把聽寫送出去。
    /// - system：一律排進去；能不能用（系統版本、語言包）執行時才知道，翻不了就換下一個。
    /// - localEditor：只有用得了才排。
    static func engines(cleanupEnabled: Bool, hasKey: Bool, localEditorUsable: Bool) -> [Engine] {
        var engines: [Engine] = []
        if cleanupEnabled && hasKey { engines.append(.cloud) }
        engines.append(.system)
        if localEditorUsable { engines.append(.localEditor) }
        return engines
    }

    /// 本機 editor 能不能用：沒設定 command＝不能；command 是內建的 utuvo-type-editor.py 時，
    /// `.models/editor` 要真的存在（安裝程式不下載它）；使用者自己設定的別的 command 照用。
    static func localEditorUsable(command: String, bundledWrapperPath: String?, bundledModelExists: Bool) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let bundledWrapperPath,
              URL(fileURLWithPath: trimmed).standardizedFileURL.path
                == URL(fileURLWithPath: bundledWrapperPath).standardizedFileURL.path else { return true }
        return bundledModelExists
    }

    /// 送進共用提示詞的目標語言名稱：中文名（「英文」）＋英文名（"English"），跟 iOS 翻譯清單同一份。
    static func promptNames(_ target: TranslationTarget) -> (zh: String, en: String) {
        (target.localizedName(zh: true), target.localizedName(zh: false))
    }

    /// 雲端翻譯要用的服務設定（整理服務那一組）。
    struct CloudRoute: Sendable, Equatable {
        var provider: SmartCleanup.Provider
        var key: String
        var customEndpoint: String
        var customModel: String
    }
}
