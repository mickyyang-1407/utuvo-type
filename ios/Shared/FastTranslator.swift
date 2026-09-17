import Foundation
#if canImport(Translation)
import Translation
#endif

/// 快速翻譯：iOS 26 的 Translation framework（系統翻譯，裝置端，語言包已安裝時）。
/// 實機實測（2026-09-17，同一句中文→英文）：Translation framework 冷 1.46 s／熱 0.65 s；
/// Apple Intelligence（FoundationModels）冷 4.32 s／熱 0.84 s。所以翻譯優先走這裡，並且提早預熱。
@MainActor
final class FastTranslator {
    static let shared = FastTranslator()

    private var sessions: [String: AnyObject] = [:]

    enum Failure: Error { case unavailable }

    /// 辨識語言（DictationLanguage.rawValue）→ 翻譯用語言。
    nonisolated static func languageIdentifier(forDictation raw: String) -> String {
        switch raw {
        case "zh-TW", "zh-HK": return "zh-Hant"
        case "zh-CN": return "zh-Hans"
        default: return String(raw.split(separator: "-").first ?? Substring(raw))
        }
    }

    private var warmed: Set<String> = []

    /// 提早建立 session 並真的翻一個短字，把翻譯模型載進記憶體（只建 session 不會熱：實機實測首譯仍 3.1 s）。
    /// 語言包已安裝才會成功；不會跳下載 UI。同一語言對只預熱一次。
    func prewarm(sourceRaw: String, targetCode: String) async {
        guard #available(iOS 26.0, *) else { return }
        let key = "\(sourceRaw)>\(targetCode)"
        guard !warmed.contains(key), let box = try? await session(sourceRaw: sourceRaw, targetCode: targetCode) else { return }
        warmed.insert(key)
        _ = try? await Self.run(box, "好")
    }

    func translate(_ text: String, sourceRaw: String, targetCode: String) async throws -> String {
        guard #available(iOS 26.0, *) else { throw Failure.unavailable }
        let box = try await session(sourceRaw: sourceRaw, targetCode: targetCode)
        return try await Self.run(box, text)
    }

    @available(iOS 26.0, *)
    nonisolated private static func run(_ box: SessionBox, _ text: String) async throws -> String {
        try await box.session.translate(text).targetText
    }

    /// TranslationSession 不是 Sendable；同一個 session 只在這裡序列使用，用盒子跨隔離區傳遞。
    @available(iOS 26.0, *)
    final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }

    @available(iOS 26.0, *)
    private func session(sourceRaw: String, targetCode: String) async throws -> SessionBox {
        let src = Locale.Language(identifier: Self.languageIdentifier(forDictation: sourceRaw))
        let dst = Locale.Language(identifier: targetCode)
        let key = "\(src.minimalIdentifier)>\(dst.minimalIdentifier)"
        if let cached = sessions[key] as? SessionBox { return cached }
        let status = await LanguageAvailability().status(from: src, to: dst)
        guard status == .installed else { throw Failure.unavailable }
        let box = SessionBox(TranslationSession(installedSource: src, target: dst))
        sessions[key] = box
        return box
    }
}
