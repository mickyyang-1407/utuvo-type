import XCTest
@testable import UTUVOTypeApp

/// capture-latency-5（2026-10-22）：「開始提示音」跟「錄音時靜音」都開時，提示音不能被自己的靜音吃掉。
/// 以前 start() 先靜音輸出、之後才播提示音——兩個都開的人永遠聽不到開始音。
@MainActor
final class RecordingCuesTests: XCTestCase {

    func testBothOnPlaysToneBeforeMuting() {
        let plan = RecordingCues.startPlan(audioFeedback: true, muteWhileRecording: true, toneDelayMs: 0)
        XCTAssertEqual(plan.toneAfterMs, 0)
        XCTAssertEqual(plan.muteAfterMs, RecordingCues.toneMilliseconds, "提示音播完才靜音")
        XCTAssertTrue(RecordingCues.defersMute(audioFeedback: true, muteWhileRecording: true))
    }

    func testBluetoothDelayShiftsBothSteps() {
        let plan = RecordingCues.startPlan(audioFeedback: true, muteWhileRecording: true, toneDelayMs: 1_200)
        XCTAssertEqual(plan, .init(toneAfterMs: 1_200, muteAfterMs: 1_200 + RecordingCues.toneMilliseconds))
    }

    /// 只開一個時跟以前一模一樣。
    func testSingleOptionKeepsOldBehaviour() {
        XCTAssertEqual(RecordingCues.startPlan(audioFeedback: false, muteWhileRecording: true, toneDelayMs: 1_200),
                       .init(toneAfterMs: nil, muteAfterMs: 0))
        XCTAssertFalse(RecordingCues.defersMute(audioFeedback: false, muteWhileRecording: true),
                       "只開靜音：照舊在 start() 裡一開始就靜音")
        XCTAssertEqual(RecordingCues.startPlan(audioFeedback: true, muteWhileRecording: false, toneDelayMs: 1_200),
                       .init(toneAfterMs: 0, muteAfterMs: nil), "只開提示音：照舊立刻播（不等藍牙延遲）")
        XCTAssertEqual(RecordingCues.startPlan(audioFeedback: false, muteWhileRecording: false, toneDelayMs: 0),
                       .init(toneAfterMs: nil, muteAfterMs: nil))
        XCTAssertFalse(RecordingCues.defersMute(audioFeedback: true, muteWhileRecording: false))
        XCTAssertEqual(RecordingCues.startPlan(audioFeedback: true, muteWhileRecording: true, toneDelayMs: -5).toneAfterMs, 0)
    }

    func testToneDelayFollowsTypelessRules() {
        XCTAssertEqual(RecordingCues.toneDelayMs(outputIsBluetooth: true, outputIsAlsoInput: true, outputName: "Headset"), 1_200)
        XCTAssertEqual(RecordingCues.toneDelayMs(outputIsBluetooth: true, outputIsAlsoInput: false, outputName: "Micky 的 AirPods Pro"), 300)
        XCTAssertEqual(RecordingCues.toneDelayMs(outputIsBluetooth: true, outputIsAlsoInput: false, outputName: "Speaker"), 0)
        XCTAssertEqual(RecordingCues.toneDelayMs(outputIsBluetooth: false, outputIsAlsoInput: false, outputName: "MacBook Pro 喇叭"), 0)
    }

    func testRunPlaysToneThenMutesInOrder() async {
        var steps: [String] = []
        await RecordingCues.run(.init(toneAfterMs: 300, muteAfterMs: 440),
                                stillRecording: { true },
                                playTone: { steps.append("tone") },
                                mute: { steps.append("mute") },
                                sleep: { steps.append("sleep \($0)") })
        XCTAssertEqual(steps, ["sleep 300", "tone", "sleep 140", "mute"])
    }

    func testRunAtSameInstantStillPlaysToneFirst() async {
        var steps: [String] = []
        await RecordingCues.run(.init(toneAfterMs: 0, muteAfterMs: 0), stillRecording: { true },
                                playTone: { steps.append("tone") }, mute: { steps.append("mute") },
                                sleep: { steps.append("sleep \($0)") })
        XCTAssertEqual(steps, ["tone", "mute"])
    }

    /// 錄音在提示音前就停了：不播、也不靜音（停止時已經還原，晚到的靜音會把喇叭留在靜音）。
    func testStoppedRecordingCancelsRemainingSteps() async {
        var steps: [String] = []
        var recording = true
        await RecordingCues.run(.init(toneAfterMs: 0, muteAfterMs: 140),
                                stillRecording: { recording },
                                playTone: { steps.append("tone"); recording = false },
                                mute: { steps.append("mute") },
                                sleep: { _ in })
        XCTAssertEqual(steps, ["tone"], "播完提示音後錄音停了：不再靜音")

        steps = []
        await RecordingCues.run(.init(toneAfterMs: 1_200, muteAfterMs: 1_340), stillRecording: { false },
                                playTone: { steps.append("tone") }, mute: { steps.append("mute") }, sleep: { _ in })
        XCTAssertEqual(steps, [])
    }
}
