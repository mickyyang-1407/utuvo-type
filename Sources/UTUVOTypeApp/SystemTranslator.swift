import Foundation
#if canImport(Translation)
import Translation
#endif

/// 系統翻譯（macOS 26 Translation framework；裝置端、語言包已安裝才用，不會跳下載畫面）。
///
/// 語音翻譯沒有雲端 key 時的第一個退路（modes-1，2026-10-22）。移植自 iOS `FastTranslator`
/// （ios/Shared/FastTranslator.swift，那份不動）。
@MainActor
final class SystemTranslator {
    static let shared = SystemTranslator()

    private var sessions: [String: AnyObject] = [:]

    /// 辨識語言（TranscriptionLanguage.rawValue）→ 翻譯用語言；「自動偵測」不知道來源語言＝nil（不用系統翻譯）。
    nonisolated static func sourceLanguage(forTranscription raw: String) -> String? {
        switch raw {
        case "auto", "": return nil
        case "zh-TW", "zh-HK": return "zh-Hant"
        case "zh-CN": return "zh-Hans"
        default: return String(raw.split(separator: "-").first ?? Substring(raw))
        }
    }

    /// 翻不了（系統太舊、語言包沒裝、來源不明、翻譯失敗）一律回 nil，由呼叫端換下一個方法。
    func translate(_ text: String, sourceRaw: String, targetCode: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }
        guard let source = Self.sourceLanguage(forTranscription: sourceRaw),
              let box = await session(source: source, target: targetCode),
              let out = try? await Self.run(box, text) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @available(macOS 26.0, *)
    nonisolated private static func run(_ box: SessionBox, _ text: String) async throws -> String {
        try await box.session.translate(text).targetText
    }

    /// TranslationSession 不是 Sendable；同一個 session 只在這裡序列使用。
    @available(macOS 26.0, *)
    final class SessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ session: TranslationSession) { self.session = session }
    }

    @available(macOS 26.0, *)
    private func session(source: String, target: String) async -> SessionBox? {
        let src = Locale.Language(identifier: source)
        let dst = Locale.Language(identifier: target)
        guard src.minimalIdentifier != dst.minimalIdentifier else { return nil }
        let key = "\(src.minimalIdentifier)>\(dst.minimalIdentifier)"
        if let cached = sessions[key] as? SessionBox { return cached }
        guard await LanguageAvailability().status(from: src, to: dst) == .installed else { return nil }
        let box = SessionBox(TranslationSession(installedSource: src, target: dst))
        sessions[key] = box
        return box
    }
}
