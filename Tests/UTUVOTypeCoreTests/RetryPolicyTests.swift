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

    /// 契約：沒有任何一條重試路徑會啟動錄音。
    func testNoDecisionEverStartsRecording() {
        let all: [RetryDecision] = [.reformatFromRawTranscript, .ignoreBusy, .needsReselection]
        for decision in all {
            XCTAssertFalse(RetryPolicy.startsRecording(decision), "\(decision) 不得啟動錄音")
        }
    }
}
