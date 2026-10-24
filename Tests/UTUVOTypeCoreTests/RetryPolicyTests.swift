import XCTest
@testable import UTUVOTypeCore

/// MAC2：釘住承諾 1 的「重試不再錄第二次」。
final class RetryPolicyTests: XCTestCase {

    func testRetryUsesRawTranscriptAndNeverRecords() {
        for mode in [FormatterMode.fast, .smart, .deep] {
            let decision = RetryPolicy.decide(mode: mode, isRecording: false, isProcessing: false)
            XCTAssertEqual(decision, .reformatFromRawTranscript, "mode \(mode) 應該直接重跑逐字稿")
            XCTAssertFalse(RetryPolicy.startsRecording(decision))
        }
    }

    func testEditSelectionNeedsReselection() {
        let decision = RetryPolicy.decide(mode: .editSelection, isRecording: false, isProcessing: false)
        XCTAssertEqual(decision, .needsReselection)
        XCTAssertFalse(RetryPolicy.startsRecording(decision))
    }

    func testRecordingBlocksRetry() {
        let decision = RetryPolicy.decide(mode: .smart, isRecording: true, isProcessing: false)
        XCTAssertEqual(decision, .ignoreBusy)
        XCTAssertFalse(RetryPolicy.startsRecording(decision))
    }

    func testProcessingBlocksRetry() {
        let decision = RetryPolicy.decide(mode: .smart, isRecording: false, isProcessing: true)
        XCTAssertEqual(decision, .ignoreBusy)
    }

    /// 順序：忙碌優先於模式限制（否則錄音中按 Edit Selection 的重試會改到狀態）。
    func testBusyCheckRunsBeforeModeCheck() {
        let decision = RetryPolicy.decide(mode: .editSelection, isRecording: true, isProcessing: true)
        XCTAssertEqual(decision, .ignoreBusy)
    }

    /// app-shell-v1：Ask anything 的紀錄是「指令＋回答」，不是聽寫，重跑整理會把指令當成要貼的字。
    func testAskAnythingEntryIsNotRetriedAsDictation() {
        XCTAssertEqual(RetryPolicy.decide(mode: .smart, isRecording: false, isProcessing: false, isAskAnything: true),
                       .notDictation)
        XCTAssertEqual(RetryPolicy.decide(mode: .smart, isRecording: false, isProcessing: false, isAskAnything: false),
                       .reformatFromRawTranscript, "一般聽寫照舊")
        XCTAssertEqual(RetryPolicy.decide(mode: .editSelection, isRecording: false, isProcessing: false, isAskAnything: false),
                       .needsReselection)
        XCTAssertEqual(RetryPolicy.decide(mode: .smart, isRecording: true, isProcessing: false, isAskAnything: true),
                       .ignoreBusy, "忙碌仍然先擋")
        XCTAssertFalse(RetryPolicy.startsRecording(.notDictation))
    }

    /// app-shell-v1：重試就地更新同一筆、不再算一次使用數據、不改預設模式、不貼到最前面的 App。
    func testRetryBookkeepingUpdatesInPlaceWithoutSideEffects() {
        XCTAssertEqual(RetryPolicy.bookkeeping(for: .reformatFromRawTranscript),
                       RetryPolicy.Bookkeeping(updatesEntryInPlace: true, countsTowardStats: false,
                                               changesDefaultMode: false, pastesIntoFrontmostApp: false))
        for decision in [RetryDecision.ignoreBusy, .needsReselection, .notDictation] {
            XCTAssertNil(RetryPolicy.bookkeeping(for: decision), "\(decision) 沒有新結果可記帳")
        }
    }

    // MARK: - delivery-learning-1／app-shell-3：辨識失敗的紀錄用存下來的錄音重新辨識

    private func decide(_ raw: String, audio: Bool, mode: FormatterMode = .smart, recording: Bool = false,
                        processing: Bool = false, ask: Bool = false) -> RetryDecision {
        RetryPolicy.decide(mode: mode, isRecording: recording, isProcessing: processing, isAskAnything: ask,
                           rawTranscript: raw, hasAudio: audio)
    }

    func testEmptyTranscriptWithAudioRetranscribes() {
        XCTAssertEqual(decide("", audio: true), .retranscribeFromAudio)
        XCTAssertEqual(decide("  \n", audio: true), .retranscribeFromAudio, "只有空白也算沒有逐字稿")
        XCTAssertEqual(decide("", audio: true, mode: .fast), .retranscribeFromAudio)
        XCTAssertFalse(RetryPolicy.startsRecording(.retranscribeFromAudio), "重新辨識拿存下來的錄音，不重新錄")
    }

    /// 有逐字稿就照舊只重新整理：不多花一次辨識（不論錄音在不在）。
    func testTranscriptPresentStillOnlyReformats() {
        XCTAssertEqual(decide("合成測試文字", audio: true), .reformatFromRawTranscript)
        XCTAssertEqual(decide("合成測試文字", audio: false), .reformatFromRawTranscript)
    }

    func testNoTranscriptAndNoAudioHasNothingToRetry() {
        XCTAssertEqual(decide("", audio: false), .nothingToRetry)
        XCTAssertFalse(RetryPolicy.startsRecording(.nothingToRetry))
        XCTAssertNil(RetryPolicy.bookkeeping(for: .nothingToRetry, entryCounted: false))
    }

    /// 順序不變：忙碌先擋，再看 Ask anything、Edit Selection，最後才看有沒有逐字稿／錄音。
    func testRetranscribeKeepsTheCheckOrder() {
        XCTAssertEqual(decide("", audio: true, recording: true), .ignoreBusy)
        XCTAssertEqual(decide("", audio: true, processing: true), .ignoreBusy)
        XCTAssertEqual(decide("", audio: true, ask: true), .notDictation)
        XCTAssertEqual(decide("", audio: true, mode: .editSelection), .needsReselection)
        XCTAssertEqual(decide("", audio: false, mode: .editSelection, processing: true), .ignoreBusy)
    }

    /// 失敗／取消的紀錄寫入時沒算使用數據：重試成功時算一次。正常的紀錄已經算過，重試不再算。
    func testRecoveredEntryCountsOnceOrdinaryRetryNever() {
        for decision in [RetryDecision.retranscribeFromAudio, .reformatFromRawTranscript] {
            XCTAssertEqual(RetryPolicy.bookkeeping(for: decision, entryCounted: false),
                           RetryPolicy.Bookkeeping(updatesEntryInPlace: true, countsTowardStats: true,
                                                   changesDefaultMode: false, pastesIntoFrontmostApp: false))
            XCTAssertEqual(RetryPolicy.bookkeeping(for: decision, entryCounted: true)?.countsTowardStats, false)
            XCTAssertEqual(RetryPolicy.bookkeeping(for: decision, entryCounted: true)?.updatesEntryInPlace, true,
                           "一律就地更新同一筆，不新增")
        }
        XCTAssertEqual(RetryPolicy.bookkeeping(for: .reformatFromRawTranscript, entryCounted: true),
                       RetryPolicy.bookkeeping(for: .reformatFromRawTranscript), "舊的記帳不變")
        for decision in [RetryDecision.ignoreBusy, .needsReselection, .notDictation] {
            XCTAssertNil(RetryPolicy.bookkeeping(for: decision, entryCounted: false))
        }
    }

    /// 契約：沒有任何一條重試路徑會啟動錄音。
    func testNoDecisionEverStartsRecording() {
        let all: [RetryDecision] = [.reformatFromRawTranscript, .ignoreBusy, .needsReselection, .notDictation,
                                    .retranscribeFromAudio, .nothingToRetry]
        for decision in all {
            XCTAssertFalse(RetryPolicy.startsRecording(decision), "\(decision) 不得啟動錄音")
        }
    }
}
