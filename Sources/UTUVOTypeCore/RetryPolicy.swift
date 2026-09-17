import Foundation

/// 歷史紀錄「重試」的唯一決策點（MAC2，2026-09-11）。
///
/// 產品承諾 1 的一半是「雲端失敗後不要求你再講一次」：重試永遠拿
/// 既有的 rawTranscript 重跑 formatter，不重新錄音。這個決策以前只
/// 活在 `AppModel.retryHistory` 裡沒有測試釘住，現在抽成純函式。
///
/// 檢查有先後順序，測試會釘住：忙碌優先於模式限制。
public enum RetryDecision: Equatable, Sendable {
    /// 用既有逐字稿重跑 formatter——**不啟動錄音**。
    case reformatFromRawTranscript
    /// 正在錄音或處理中：忽略這次重試。
    case ignoreBusy
    /// Edit Selection 的原始選取文字已不在手上，需要使用者重新選取。
    case needsReselection
}

public enum RetryPolicy: Sendable {
    /// - Parameters:
    ///   - mode: 該筆歷史當初使用的模式。
    ///   - isRecording: 目前是否正在錄音。
    ///   - isProcessing: 目前是否正在處理（formatter 進行中）。
    public static func decide(
        mode: FormatterMode,
        isRecording: Bool,
        isProcessing: Bool
    ) -> RetryDecision {
        // 順序固定：忙碌先擋，避免在錄音中途改 activeMode。
        if isRecording || isProcessing { return .ignoreBusy }
        if mode == .editSelection { return .needsReselection }
        return .reformatFromRawTranscript
    }

    /// 這個決策會不會啟動錄音？契約上永遠是 false——
    /// 任何讓重試重新錄音的改動都會弄紅 `RetryPolicyTests`。
    public static func startsRecording(_ decision: RetryDecision) -> Bool {
        switch decision {
        case .reformatFromRawTranscript, .ignoreBusy, .needsReselection:
            return false
        }
    }
}
