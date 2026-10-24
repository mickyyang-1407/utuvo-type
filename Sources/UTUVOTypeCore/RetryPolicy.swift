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
    /// Ask anything 的紀錄：逐字稿是「指令」不是聽寫，重跑整理會把指令當成要貼的字（app-shell-v1）。
    case notDictation
    /// 辨識失敗／轉錄前就取消的紀錄：沒有逐字稿，但錄音檔還在——拿**存下來的錄音**重新辨識再整理
    /// （delivery-learning-1／app-shell-3）。一樣**不啟動錄音**，不要求使用者再講一次。
    case retranscribeFromAudio
    /// 沒有逐字稿、錄音也不在了（例如被錄音保留期限刪掉）：沒有東西可以重跑。
    case nothingToRetry
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

    /// 同上，再分辨 Ask anything 的紀錄（它不是聽寫，不能重跑整理）。順序仍是忙碌先擋。
    public static func decide(
        mode: FormatterMode,
        isRecording: Bool,
        isProcessing: Bool,
        isAskAnything: Bool
    ) -> RetryDecision {
        if isRecording || isProcessing { return .ignoreBusy }
        if isAskAnything { return .notDictation }
        return decide(mode: mode, isRecording: false, isProcessing: false)
    }

    /// 同上，再看這筆有沒有逐字稿、錄音還在不在（delivery-learning-1／app-shell-3，2026-10-22）。
    /// 順序：忙碌 → Ask anything → Edit Selection → 有逐字稿就重新整理 → 沒逐字稿但有錄音就重新辨識 → 都沒有。
    /// 有逐字稿時一律只重新整理（不重新辨識）：跟以前一樣、不多花一次辨識。
    public static func decide(
        mode: FormatterMode,
        isRecording: Bool,
        isProcessing: Bool,
        isAskAnything: Bool,
        rawTranscript: String,
        hasAudio: Bool
    ) -> RetryDecision {
        let base = decide(mode: mode, isRecording: isRecording, isProcessing: isProcessing, isAskAnything: isAskAnything)
        guard base == .reformatFromRawTranscript,
              rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return hasAudio ? .retranscribeFromAudio : .nothingToRetry
    }

    /// 這個決策會不會啟動錄音？契約上永遠是 false——
    /// 任何讓重試重新錄音的改動都會弄紅 `RetryPolicyTests`。
    public static func startsRecording(_ decision: RetryDecision) -> Bool {
        switch decision {
        case .reformatFromRawTranscript, .ignoreBusy, .needsReselection, .notDictation,
             .retranscribeFromAudio, .nothingToRetry:
            return false
        }
    }

    /// 重試的結果怎麼記帳（app-shell-v1，2026-10-22）。Typeless 重試是同一筆音訊重跑、更新同一筆歷史。
    /// 以前 Mac 的重試會新增一筆重複紀錄、使用數據再算一次、偷偷改掉預設模式，還要貼到「最前面的 App」
    /// ——從設定視窗按重試時，最前面的就是 Type 自己。
    public struct Bookkeeping: Equatable, Sendable {
        /// 更新原本那一筆（同一個 id），不新增一筆。
        public var updatesEntryInPlace: Bool
        /// 字數／秒數／次數／連續天數要不要再算一次。
        public var countsTowardStats: Bool
        /// 要不要把那筆紀錄的模式寫回使用者的預設模式。
        public var changesDefaultMode: Bool
        /// 要不要貼到目前最前面的 App；不貼就把結果放進剪貼簿。
        public var pastesIntoFrontmostApp: Bool
    }

    /// 只有 `.reformatFromRawTranscript` 會產生新結果；其他決策沒有結果可記帳（nil）。
    public static func bookkeeping(for decision: RetryDecision) -> Bookkeeping? {
        guard decision == .reformatFromRawTranscript else { return nil }
        return Bookkeeping(updatesEntryInPlace: true, countsTowardStats: false,
                           changesDefaultMode: false, pastesIntoFrontmostApp: false)
    }

    /// 同上，加上重新辨識（delivery-learning-1）。`entryCounted`＝這筆當初有沒有算進使用數據：
    /// 失敗／取消的紀錄寫入時不算，重試成功時才算**一次**；正常的紀錄已經算過，重試不再算（app-shell-v1）。
    public static func bookkeeping(for decision: RetryDecision, entryCounted: Bool) -> Bookkeeping? {
        guard decision == .reformatFromRawTranscript || decision == .retranscribeFromAudio else { return nil }
        return Bookkeeping(updatesEntryInPlace: true, countsTowardStats: !entryCounted,
                           changesDefaultMode: false, pastesIntoFrontmostApp: false)
    }
}
