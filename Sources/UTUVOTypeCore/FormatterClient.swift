import Foundation

/// UTUVO Type — formatter adapter contract (M0 only).
///
/// 這個 protocol 是 M2 才會有實作的介面。M0 不實作，但介面固定住，
/// 之後不論接百鍊 WebSocket、本機 27B、或測試 fake，
/// 都要遵守這份契約。

public enum FormatterError: Error, CustomStringConvertible {
    case timeout
    case unavailable(String)
    case malformedResponse(String)
    case refused(String)

    public var description: String {
        switch self {
        case .timeout: return "formatter timeout"
        case .unavailable(let m): return "formatter unavailable: \(m)"
        case .malformedResponse(let r): return "formatter malformed response: \(r)"
        case .refused(let r): return "formatter refused: \(r)"
        }
    }
}

public protocol FormatterClient: Sendable {
    /// 同步介面：送出 prompt 與 model id，回傳 content-only 的純文字。
    /// M0 不實作；測試可注入 fake。
    func format(prompt: String, model: String) async throws -> String
}

public protocol LocalDeepFormatter: Sendable {
    /// 本機 27B 等大型模型的呼叫介面。
    /// M0 不實作；adapter 載入由 M3 處理，本里程碑不自動下載權重。
    func format(_ text: String) async throws -> String
}

/// deterministic fallback：當任何 FormatterClient 失敗時退回這個。
/// 它的存在是產品的「永遠有東西可以貼上」承諾的實作。
public enum DeterministicFallback: Sendable {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let rawTranscript: String
        public let reason: String

        public init(text: String, rawTranscript: String, reason: String) {
            self.text = text
            self.rawTranscript = rawTranscript
            self.reason = reason
        }
    }

    /// The paste payload is usable text; raw transcript is retained as a
    /// separate field for retry/copy/debug UI and is never mixed into paste.
    public static func resolve(_ normalized: NormalizedText, error: FormatterError) -> Result {
        Result(
            text: normalized.cleaned,
            rawTranscript: normalized.original,
            reason: error.description
        )
    }

    public static func render(_ normalized: NormalizedText) -> String {
        normalized.cleaned
    }
}
