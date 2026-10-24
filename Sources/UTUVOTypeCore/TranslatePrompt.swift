import Foundation

/// 語音翻譯的提示詞（modes-1，2026-10-22）：三個平台同一句。
///
/// iOS `OnDeviceAssistant.translate`（ios/Shared/OnDeviceAssistant.swift）與 Android `Assistant.translateSystem`
/// （android/app/.../Assistant.kt）早就是同一句；Mac 以前用本機小型 editor 自己一套英文提示詞，
/// 新裝的 Mac 根本沒有那個模型，翻譯直接退回原文。現在 Mac 走使用者自己的整理服務 key，提示詞用這一份，
/// `TranslatePromptParityTests` 讀 iOS／Android 原始碼逐字比對，任何一邊改了都會變紅。
public enum TranslatePrompt: Sendable {
    /// - Parameters:
    ///   - targetZh: 目標語言的繁中名稱（「英文」「日文」…），跟 iOS `TranslationTarget.zh` 同一份名稱。
    ///   - targetEn: 目標語言的英文名稱（"English"、"Japanese"…）。
    public static func system(targetZh: String, targetEn: String) -> String {
        "你是翻譯引擎。把使用者的文字翻成\(targetZh)（\(targetEn)），只輸出翻譯本身，不要解釋、不要引號。"
    }

    /// 模型偶爾會包 code fence 或前後留白；翻譯結果天然跟原文不像，不經整理把關，只做這一步。
    public static func cleanOutput(_ raw: String) -> String {
        raw.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
