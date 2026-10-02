import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 「說出要怎麼改」與「放開就翻譯」的文字引擎。
/// 優先：iOS 26 的 Apple Intelligence 裝置端模型（FoundationModels，文字不離機）；
/// 退路：使用者在「智慧整理」設定的雲端 key（Groq／Gemini／百鍊／自訂，`SmartCleanup.complete`）；
/// 裝置端失敗也會退到雲端（09-29：iOS 27.0 的 Apple Intelligence 回報可用，但每次生成都因系統的內容安全模型
/// 載不起來而失敗——SensitiveContentAnalysisML 15／ModelManagerError 1001，連 "hello" 都一樣，macOS 27 實測同樣）。
/// 都不行：講清楚哪一段壞、怎麼補，不丟一句「無法完成作業」。
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
        if SmartCleanup.completionRoute() != nil { return .cloud }
        return .unavailable(String(localized: "需要 iOS 26 的 Apple Intelligence，或在主 app 設定雲端 key"))
    }

    /// Debug 版限定：UI 測試用來模擬「沒有 Apple Intelligence」（主 app 收 launch arg 後寫進 App Group）。
    static let debugDisableKey = "utuvo.type.debug.noOnDeviceAI"

    static var onDeviceAvailable: Bool {
        #if DEBUG
        if KeyboardPresence.defaults.bool(forKey: debugDisableKey) { return false }
        #endif
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

    typealias Completion = @Sendable (String, String) async throws -> String

    private static func run(system: String, user: String) async throws -> String {
        var onDevice: Completion?
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), onDeviceAvailable {
            onDevice = { system, user in
                // 改寫／翻譯的是使用者自己的文字：用 Apple 為「內容轉換」設計的護欄，少誤擋。
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let session = LanguageModelSession(model: model, instructions: system)
                return try await session.respond(to: user).content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        #endif
        var cloud: Completion?
        if let route = SmartCleanup.completionRoute() {
            cloud = { system, user in
                try await SmartCleanup.complete(system: system, user: user, provider: route.provider, key: route.key)
            }
        }
        return try await run(system: system, user: user, onDevice: onDevice, cloud: cloud)
    }

    /// 裝置端優先；裝置端出錯就換雲端；兩邊都沒有或都失敗，丟出說得清楚的錯誤。
    static func run(system: String, user: String, onDevice: Completion?, cloud: Completion?) async throws -> String {
        var onDeviceError: Error?
        if let onDevice {
            do {
                let out = try await onDevice(system, user)
                if !out.isEmpty { return out }
                onDeviceError = AssistantError.emptyOutput
            } catch {
                onDeviceError = error
            }
        }
        guard let cloud else {
            if let onDeviceError { throw AssistantError.onDeviceFailed(detail: describe(onDeviceError)) }
            throw AssistantError.unavailable
        }
        do {
            let out = try await cloud(system, user)
            guard !out.isEmpty else { throw AssistantError.emptyOutput }
            return out
        } catch {
            throw AssistantError.cloudFailed(detail: describe(error), afterOnDevice: onDeviceError != nil)
        }
    }

    /// 錯誤翻成看得懂的一句話。鍵盤提示只有兩行（約 30 個中文字），補救方法要放得進去。
    static func describe(_ error: Error) -> String {
        var chain: [NSError] = []
        var queue: [NSError] = [error as NSError]
        while let e = queue.first, chain.count < 8 {
            queue.removeFirst()
            chain.append(e)
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(u) }
            queue += (e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError]) ?? []
        }
        let domains = chain.map(\.domain).joined(separator: " ")
        if domains.contains("SensitiveContentAnalysis") || domains.contains("ModelManager") {
            return String(localized: "Apple Intelligence 暫時不能用")
        }
        if let failure = error as? SmartCleanup.Failure {
            switch failure {
            case .http(401), .http(403): return String(localized: "雲端 key 被拒：到設定→智慧整理重貼")
            case .http(429): return String(localized: "雲端免費額度用完了（429）")
            case .http(let code): return String(localized: "雲端回應錯誤 \(code)")
            case .timeout: return String(localized: "雲端逾時")
            default: return String(localized: "雲端回應看不懂")
            }
        }
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return String(localized: "連不上網：鍵盤要開「允許完整取用」")
        }
        let first = chain.first.map { "\($0.domain) \($0.code)" } ?? ""
        return String(localized: "Apple Intelligence 失敗（\(first)）")
    }

    enum AssistantError: LocalizedError {
        case unavailable
        case emptyOutput
        case onDeviceFailed(detail: String)
        case cloudFailed(detail: String, afterOnDevice: Bool)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(localized: "沒有 Apple Intelligence：到設定→智慧整理加 Groq key")
            case .emptyOutput:
                return String(localized: "模型沒有回傳內容")
            case .onDeviceFailed(let detail):
                return String(localized: "\(detail)：到設定→智慧整理加 Groq key")
            case .cloudFailed(let detail, let afterOnDevice):
                return afterOnDevice
                    ? String(localized: "Apple Intelligence 和雲端都失敗：\(detail)")
                    : detail
            }
        }
    }
}
