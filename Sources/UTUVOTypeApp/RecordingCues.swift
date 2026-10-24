import Foundation

/// 開始錄音的提示音與「錄音時靜音」的先後（capture-latency-5，2026-10-22）。
///
/// 以前 `AudioCaptureSession.start()` 先把輸出裝置靜音、AppModel 之後才播開始提示音，
/// 提示音播到同一個已經靜音的裝置上——兩個選項都開的人永遠聽不到開始音。
/// Typeless 是先播音、等一下才靜音；耳機又錄又放時還會先等耳機切換完（A2DP → HFP）。
///
/// 只有兩個選項都開時順序才不同；只開一個時跟以前一樣（只播音／錄音一開始就靜音）。
/// 結束時順序不變：`capture.stop()` 先還原靜音，之後才播結束音。
enum RecordingCues {
    /// 提示音長度：`FeedbackTonePlayer` 播 90 ms，140 ms 時停引擎。
    static let toneMilliseconds = 140

    struct StartPlan: Equatable {
        /// 錄音開始後幾毫秒播開始音；nil＝不播。
        var toneAfterMs: Int?
        /// 錄音開始後幾毫秒靜音輸出；nil＝不靜音，0＝錄音一開始就靜音（跟以前一樣在 start() 裡做）。
        var muteAfterMs: Int?
    }

    static func startPlan(audioFeedback: Bool, muteWhileRecording: Bool, toneDelayMs: Int) -> StartPlan {
        switch (audioFeedback, muteWhileRecording) {
        case (false, false): return StartPlan(toneAfterMs: nil, muteAfterMs: nil)
        case (true, false): return StartPlan(toneAfterMs: 0, muteAfterMs: nil)
        case (false, true): return StartPlan(toneAfterMs: nil, muteAfterMs: 0)
        case (true, true):
            let delay = max(0, toneDelayMs)
            return StartPlan(toneAfterMs: delay, muteAfterMs: delay + toneMilliseconds)
        }
    }

    /// 錄音時靜音要不要延後到提示音之後（＝兩個選項都開）。
    static func defersMute(audioFeedback: Bool, muteWhileRecording: Bool) -> Bool {
        audioFeedback && muteWhileRecording
    }

    /// Typeless `startRecordingPlayAlertSoundDelayTime`：輸出跟輸入是同一支藍牙耳機 1200 ms、
    /// 輸出是 AirPods 300 ms、其他 0（開麥會讓耳機從 A2DP 切到 HFP，立刻播的音會被吃掉）。
    static func toneDelayMs(outputIsBluetooth: Bool, outputIsAlsoInput: Bool, outputName: String) -> Int {
        if outputIsBluetooth && outputIsAlsoInput { return 1_200 }
        if outputName.localizedCaseInsensitiveContains("AirPods") { return 300 }
        return 0
    }

    /// 照計畫依序執行。每一步前都問 `stillRecording`：錄音已經停了就不再播、也不再靜音
    /// （停止時已經還原了，這時才靜音會把喇叭留在靜音）。
    @MainActor
    static func run(_ plan: StartPlan,
                    stillRecording: () -> Bool,
                    playTone: () -> Void,
                    mute: () -> Void,
                    sleep: (Int) async -> Void) async {
        var steps: [(at: Int, isTone: Bool)] = []
        if let tone = plan.toneAfterMs { steps.append((tone, true)) }
        if let muteAt = plan.muteAfterMs { steps.append((muteAt, false)) }
        // 同一時間時提示音先。
        steps.sort { $0.at == $1.at ? $0.isTone && !$1.isTone : $0.at < $1.at }
        var now = 0
        for step in steps {
            if step.at > now { await sleep(step.at - now); now = step.at }
            guard stillRecording() else { return }
            if step.isTone { playTone() } else { mute() }
        }
    }
}
