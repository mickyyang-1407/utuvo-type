import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 「說出要怎麼改」與「放開就翻譯」的文字引擎。
/// 優先：iOS 26 的 Apple Intelligence 裝置端模型（FoundationModels，文字不離機）；
/// 退路：使用者自己填的雲端 key（TranslationService，DashScope 相容）；
/// 都沒有：明講不可用，不假裝。
enum OnDeviceAssistant {
    enum Engine: Equatable, Sendable {
        case appleIntelligence
        case cloud
        case unavailable(String)

        var badge: String {
            switch self {
            case .appleIntelligence: return String(localized: "Apple Intelligence・裝置端")
            case .cloud: return String(localized: "雲端（你的 key）")
            case .unavailable: return String(localized: "不可用")
            }
        }
    }

    static func currentEngine() -> Engine {
        if onDeviceAvailable { return .appleIntelligence }
        if TranslationService.shared.isConfigured { return .cloud }
        return .unavailable(String(localized: "需要 iOS 26 的 Apple Intelligence，或在主 app 設定雲端 key"))
    }

    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// 改寫選取文字。`instruction` 是使用者講的話（例如「改成正式一點」「加上咖啡」）。
    static func editSelection(_ selection: String, instruction: String) async throws -> String {
        let system = """
        你是文字編輯器。使用者會給你一段「原文」和一句「指示」。\
        依指示修改原文，只輸出修改後的文字：不要解釋、不要引號、不要加標題、保留原文語言與大致長度。\
        指示若是要新增內容，就在合適位置加進去；若是要改語氣，就整段改寫。
        """
        let user = "原文：\n\(selection)\n\n指示：\(instruction)"
        return try await run(system: system, user: user)
    }

    /// 翻譯成目標語言，只回翻譯。系統翻譯（已裝語言包）優先，再來 Apple Intelligence／雲端 key。
    @MainActor
    static func translate(_ text: String, to target: TranslationTarget, sourceRaw: String) async throws -> String {
        if let fast = try? await FastTranslator.shared.translate(text, sourceRaw: sourceRaw, targetCode: target.code) {
            return fast
        }
        return try await translate(text, to: target)
    }

    /// 翻譯成目標語言，只回翻譯（LLM 路徑）。
    static func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        let system = "你是翻譯引擎。把使用者的文字翻成\(target.zh)（\(target.en)），只輸出翻譯本身，不要解釋、不要引號。"
        return try await run(system: system, user: text)
    }

    private static func run(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), onDeviceAvailable {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        guard TranslationService.shared.isConfigured else {
            throw AssistantError.unavailable
        }
        return try await TranslationService.shared.complete(system: system, user: user)
    }

    enum AssistantError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "這台裝置沒有 Apple Intelligence（iOS 26），也沒設雲端 key；到主 app 設定 → 雲端翻譯加入 key 即可")
        }
    }
}
