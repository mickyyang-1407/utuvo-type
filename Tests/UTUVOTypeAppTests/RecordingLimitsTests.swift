import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// capture-latency-v3（2026-10-22）：Mac 忘記關麥的保護。時間全由測試傳入，不開麥克風。
final class RecordingLimitsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testDefaultsFollowTypelessAndGroqLimits() {
        XCTAssertEqual(RecordingLimits.maxSeconds, 540, "Typeless MAX_DURATION 9 分鐘")
        XCTAssertEqual(RecordingLimits.warningSeconds, 60, "最後 1 分鐘倒數")
        XCTAssertEqual(RecordingLimits.longSilenceSeconds, 60)
        XCTAssertEqual(RecordingLimits.longSilenceWarningSeconds, 30, "安靜停止前倒數 30 秒（repair-batch1）")
        XCTAssertEqual(MacCloudASR.maxSeconds, 300, "Groq 一次收的上限")
        // repair-batch1：原本釘 300（＝Groq 上限），被截斷的錄音一定超過 300 秒、Groq 拒收。改成 Groq 上限扣 5 秒餘裕。
        XCTAssertEqual(RecordingLimits.maxDuration(cloudOnly: true), 295, "只有 Groq 時：Groq 上限扣 5 秒餘裕")
        XCTAssertEqual(RecordingLimits.maxDuration(cloudOnly: false), 540)
    }

    /// 一直在講話：前面都不打擾，最後 60 秒倒數，到上限照常停止（一次）。
    func testCountdownThenSingleStopAtTheLimit() {
        var limits = RecordingLimits(startedAt: start, maxDuration: 300)
        for second in stride(from: 1.0, through: 239, by: 1) {
            XCTAssertEqual(limits.check(now: at(second), lastVoiceAt: at(second)), .none, "第 \(second) 秒")
        }
        XCTAssertEqual(limits.check(now: at(240), lastVoiceAt: at(240)), .countdown(secondsLeft: 60))
        XCTAssertEqual(limits.check(now: at(240.4), lastVoiceAt: at(240.4)), .countdown(secondsLeft: 60), "無條件進位")
        XCTAssertEqual(limits.check(now: at(299.5), lastVoiceAt: at(299.5)), .countdown(secondsLeft: 1))
        XCTAssertEqual(limits.check(now: at(300), lastVoiceAt: at(300)), .stop(.maxDuration))
        XCTAssertEqual(limits.check(now: at(301), lastVoiceAt: at(301)), .none, "只停一次")
        XCTAssertEqual(limits.check(now: at(900), lastVoiceAt: nil), .none)
    }

    /// 開了沒講話（或講完忘了關）：60 秒沒聲音開始倒數 30 秒，倒數完才停，不必等到上限。
    /// repair-batch1：原本 60 秒一到就直接停（沒有任何預警）；停止點的兩個斷言改成「先倒數、倒數完才停」。
    func testLongSilenceStops() {
        var never = RecordingLimits(startedAt: start)
        XCTAssertEqual(never.check(now: at(59), lastVoiceAt: nil), .none)
        XCTAssertEqual(never.check(now: at(60), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 30), "先倒數，不直接停")
        XCTAssertEqual(never.check(now: at(61), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 29))
        XCTAssertEqual(never.check(now: at(89.5), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 1))
        XCTAssertEqual(never.check(now: at(90), lastVoiceAt: nil), .stop(.longSilence))
        XCTAssertEqual(never.check(now: at(91), lastVoiceAt: nil), .none, "只停一次")

        var spoke = RecordingLimits(startedAt: start)
        XCTAssertEqual(spoke.check(now: at(100), lastVoiceAt: at(45)), .none, "安靜 55 秒還不停")
        XCTAssertEqual(spoke.check(now: at(105), lastVoiceAt: at(45)), .silenceCountdown(secondsLeft: 30))
        XCTAssertEqual(spoke.check(now: at(135), lastVoiceAt: at(45)), .stop(.longSilence))

        // 上一次錄音留下的時間（早於這次開始）不算：從開始算起。
        var stale = RecordingLimits(startedAt: start)
        XCTAssertEqual(stale.check(now: at(30), lastVoiceAt: at(-500)), .none)
    }

    /// 每 50 秒講一句的長段口述：不會被當成安靜；照樣在 8 分鐘開始倒數、9 分鐘停。
    func testSteadySpeechWithPausesIsNeverCutForSilence() {
        var limits = RecordingLimits(startedAt: start)
        var lastVoice: Date?
        var actions: [RecordingLimits.Action] = []
        for second in stride(from: 1.0, through: 540, by: 1) {
            if second.truncatingRemainder(dividingBy: 50) == 0 { lastVoice = at(second) }
            actions.append(limits.check(now: at(second), lastVoiceAt: lastVoice))
        }
        XCTAssertFalse(actions.contains(.stop(.longSilence)))
        XCTAssertEqual(actions.firstIndex { if case .countdown = $0 { return true }; return false }.map { $0 + 1 }, 480)
        XCTAssertEqual(actions.last, .stop(.maxDuration))
        XCTAssertEqual(actions.filter { if case .stop = $0 { return true }; return false }.count, 1)
    }

    /// 上限比倒數還短（只錄 30 秒的設定）：一開始就倒數，不會算出負數。
    func testShortLimitCountsDownFromTheStart() {
        var limits = RecordingLimits(startedAt: start, maxDuration: 30, warningLead: 60, longSilence: 600)
        XCTAssertEqual(limits.check(now: at(0), lastVoiceAt: nil), .countdown(secondsLeft: 30))
        XCTAssertEqual(limits.check(now: at(29.01), lastVoiceAt: nil), .countdown(secondsLeft: 1))
        XCTAssertEqual(limits.check(now: at(30), lastVoiceAt: nil), .stop(.maxDuration))
    }

    // MARK: - repair-batch1：上限要留餘裕、安靜停止前要先倒數

    /// 只有 Groq 時的上限要比 Groq 收的 300 秒短：每秒才檢查一次、停止要一點時間、引擎比計時先開始，
    /// 上限剛好 300 秒的話，被截斷的錄音一定超過 300 秒，Groq 直接拒收（"too-long"），重試也救不回來。
    func testCloudOnlyCapLeavesHeadroomBelowGroqLimit() {
        XCTAssertLessThan(RecordingLimits.maxDuration(cloudOnly: true), MacCloudASR.maxSeconds)
        XCTAssertLessThanOrEqual(RecordingLimits.maxDuration(cloudOnly: true), MacCloudASR.maxSeconds - 5, "至少 5 秒餘裕")
    }

    /// 從頭到尾沒聲音：自動停止之前一定先有倒數（不能毫無預警就停）。
    func testLongSilenceStopIsPrecededByACountdown() {
        var limits = RecordingLimits(startedAt: start)
        var actions: [RecordingLimits.Action] = []
        for second in stride(from: 1.0, through: 600, by: 1) {
            let action = limits.check(now: at(second), lastVoiceAt: nil)
            actions.append(action)
            if case .stop = action { break }
        }
        let stopIndex = actions.firstIndex { if case .stop = $0 { return true }; return false }
        XCTAssertNotNil(stopIndex, "最後還是會停")
        let warned = actions.prefix(stopIndex ?? 0).filter { $0 != .none }.count
        XCTAssertGreaterThanOrEqual(warned, 10, "停之前至少倒數 10 秒（每秒一次）")
    }

    // MARK: - 錄音端：「最後有聲音的時間」不管「安靜時自動結束」開不開都要記

    /// 以前只有開了「安靜時自動結束」（預設關）才算電平：預設設定下 60 秒保護拿不到資料。
    func testVoiceActivityIsTrackedEvenWithAutoStopOff() {
        let session = AudioCaptureSession(voiceActivityDetection: false)
        XCTAssertNil(session.lastVoiceActivity)
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.001, at: at(1)))
        XCTAssertNil(session.lastVoiceActivity, "安靜不算有聲音")
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.2, at: at(2)))
        XCTAssertEqual(session.lastVoiceActivity, at(2))
        XCTAssertFalse(session.noteVoiceLevel(rms: AudioCaptureSession.voiceRMSThreshold, at: at(3)), "剛好在門檻上不算")
        XCTAssertEqual(session.lastVoiceActivity, at(2))
    }

    /// 「安靜時自動結束」3 秒的判斷不變：講過話之後安靜滿 3 秒回一次 true。
    func testThreeSecondAutoStopDecisionIsUnchanged() {
        let session = AudioCaptureSession(voiceActivityDetection: true)
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.001, at: at(0)))
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.001, at: at(10)), "還沒講話就不停")
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.2, at: at(11)))
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.001, at: at(13.9)))
        XCTAssertTrue(session.noteVoiceLevel(rms: 0.001, at: at(14)))
        XCTAssertFalse(session.noteVoiceLevel(rms: 0.001, at: at(20)), "只回一次")
    }

    // MARK: - repair-batch1：上限按實際錄到的音訊算，截斷的錄音 Groq 收得下

    /// 引擎比上限計時早開始（那一段也會送去 Groq）：長度按錄到的音訊算，不是按牆上時鐘。
    func testCapIsMeasuredOnCapturedAudioNotWallClock() {
        var limits = RecordingLimits(startedAt: start, maxDuration: 295)
        XCTAssertEqual(limits.check(now: at(293), capturedSeconds: 294.2, lastVoiceAt: at(293)), .countdown(secondsLeft: 1),
                       "倒數跟著錄到的長度走")
        XCTAssertEqual(limits.check(now: at(294), capturedSeconds: 295.1, lastVoiceAt: at(294)), .stop(.maxDuration),
                       "牆上時鐘還沒到 295，錄到的已經到了")
        // 引擎卡住、錄到的比較少：牆上時鐘照樣會停（取長的那個）。
        var stalled = RecordingLimits(startedAt: start, maxDuration: 295)
        XCTAssertEqual(stalled.check(now: at(295), capturedSeconds: 120, lastVoiceAt: at(295)), .stop(.maxDuration))
    }

    func testCapturedSecondsTakesTheLongerOfFileFramesAndStreamedPCM() {
        XCTAssertEqual(AudioCaptureSession.capturedSeconds(frames: 48_000 * 10, sampleRate: 48_000, pcmBytes: 0), 10)
        XCTAssertEqual(AudioCaptureSession.capturedSeconds(frames: 48_000 * 10, sampleRate: 48_000, pcmBytes: 32_000 * 11), 11)
        XCTAssertEqual(AudioCaptureSession.capturedSeconds(frames: 0, sampleRate: 0, pcmBytes: 0), 0)
    }

    private func tonePCM(seconds: Double) -> Data {
        let count = Int(seconds * 16_000)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count { samples[i] = Int16(sin(Double(i) * 2 * .pi * 440 / 16_000) * 8_000) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 只有 Groq 的設定一直講到上限：模擬實際的時序（引擎比計時早 0.8 秒、每秒檢查一次、tap 一格 2048 frames @ 48 kHz、
    /// 停止再多收 1 秒），被截斷的錄音要通過 MacCloudASR 的長度檢查（不能是 "too-long"），Groq 才收得下。
    func testGroqOnlyCappedRecordingIsAcceptedByGroqLengthCheck() async throws {
        let cap = RecordingLimits.maxDuration(cloudOnly: true)
        let preRoll = 0.8
        let tapBuffer = 2_048.0 / 48_000
        var limits = RecordingLimits(startedAt: start, maxDuration: cap)
        var capturedAtStop: Double?
        for tick in 1...400 {
            let wall = Double(tick) + 0.37   // 計時器不會剛好整秒醒來
            let captured = ((wall + preRoll) / tapBuffer).rounded(.down) * tapBuffer
            if case .stop(.maxDuration) = limits.check(now: at(wall), capturedSeconds: captured, lastVoiceAt: at(wall)) {
                capturedAtStop = captured
                break
            }
        }
        let stoppedAt = try XCTUnwrap(capturedAtStop)
        let delivered = stoppedAt + 1.0   // 停止要一點時間：再多收 1 秒才拆 tap
        XCTAssertLessThanOrEqual(delivered, MacCloudASR.maxSeconds, "截斷的錄音（\(delivered) 秒）不能超過 Groq 的上限")

        let transport = MockCleanupTransport()
        transport.register(host: "api.groq.com", bodyJSON: ["text": "合成測試文字"])
        let outcome = await MacCloudASR.transcribe(pcm16: tonePCM(seconds: delivered), language: "zh-TW", hotwords: [],
                                                   outputScript: .traditional, key: "fake-groq-key", transport: transport)
        XCTAssertEqual(outcome, .ok("合成測試文字"), "Groq 收得下")
        XCTAssertEqual(transport.callCount, 1)

        // 對照：超過上限的確會被長度檢查擋掉（這個檢查是真的）。
        let over = await MacCloudASR.transcribe(pcm16: tonePCM(seconds: MacCloudASR.maxSeconds + 0.5), language: "zh-TW",
                                                hotwords: [], outputScript: .traditional, key: "fake-groq-key",
                                                transport: transport)
        XCTAssertEqual(over, .skipped("too-long"))
    }

    // MARK: - repair-batch1：很久沒聲音的停止要保守

    /// 小聲講話（RMS 0.012 ≈ −38 dBFS，以前的 0.015 門檻以下）、麥克風離得遠（0.004 ≈ −48 dBFS）都算有聲音；
    /// 麥克風雜訊地板（0.0005 ≈ −66 dBFS）與數位靜音才算安靜。3 秒「安靜時自動結束」的門檻不變。
    func testQuietTalkerCountsAsSoundForTheLongSilenceGuard() {
        let session = AudioCaptureSession(voiceActivityDetection: false)
        XCTAssertNil(session.lastSoundActivity)
        _ = session.noteVoiceLevel(rms: 0, at: at(1))
        _ = session.noteVoiceLevel(rms: 0.0005, at: at(2))
        XCTAssertNil(session.lastSoundActivity, "雜訊地板、數位靜音不算聲音")
        _ = session.noteVoiceLevel(rms: 0.012, at: at(3))
        XCTAssertEqual(session.lastSoundActivity, at(3), "小聲講話算有聲音")
        XCTAssertNil(session.lastVoiceActivity, "3 秒自動結束的門檻不變（0.012 不過 0.015）")
        _ = session.noteVoiceLevel(rms: 0.004, at: at(4))
        XCTAssertEqual(session.lastSoundActivity, at(4), "遠一點的麥克風也算")
        XCTAssertLessThan(AudioCaptureSession.longSilenceActivityRMS, AudioCaptureSession.voiceRMSThreshold / 5,
                          "比 3 秒自動結束的門檻低很多（至少 14 dB）")
    }

    /// 小聲的人講 8 分鐘（每 20 秒講 1 秒、其他時間是雜訊地板）：從頭到尾不出現安靜倒數、不會被安靜停止。
    func testQuietTalkerIsNeverCutForSilence() {
        let session = AudioCaptureSession(voiceActivityDetection: false)
        var limits = RecordingLimits(startedAt: start)
        var actions: [RecordingLimits.Action] = []
        for tenth in 1...4_800 {
            let t = Double(tenth) / 10
            let speaking = t.truncatingRemainder(dividingBy: 20) < 1
            _ = session.noteVoiceLevel(rms: speaking ? 0.012 : 0.0004, at: at(t))
            if tenth % 10 == 0 { actions.append(limits.check(now: at(t), lastVoiceAt: session.lastSoundActivity)) }
        }
        XCTAssertFalse(actions.contains { if case .silenceCountdown = $0 { return true }; return false })
        XCTAssertFalse(actions.contains(.stop(.longSilence)))
    }

    /// 倒數一定先出現、出現滿 30 秒才停：中間漏了好幾次檢查（App 卡住）也不會直接停。
    func testSilenceStopNeedsTheFullCountdownEvenIfChecksWereMissed() {
        var limits = RecordingLimits(startedAt: start)
        XCTAssertEqual(limits.check(now: at(59), lastVoiceAt: nil), .none)
        XCTAssertEqual(limits.check(now: at(200), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 30), "卡住後第一次：先倒數")
        XCTAssertEqual(limits.check(now: at(229), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 1))
        XCTAssertEqual(limits.check(now: at(230), lastVoiceAt: nil), .stop(.longSilence))
    }

    /// 倒數中講話：倒數取消（回 .none），之後再安靜 60 秒才重新倒數。
    func testSoundDuringSilenceCountdownCancelsIt() {
        var limits = RecordingLimits(startedAt: start)
        XCTAssertEqual(limits.check(now: at(60), lastVoiceAt: nil), .silenceCountdown(secondsLeft: 30))
        XCTAssertEqual(limits.check(now: at(70), lastVoiceAt: at(69.5)), .none, "講話就取消")
        XCTAssertEqual(limits.check(now: at(129), lastVoiceAt: at(69.5)), .none)
        XCTAssertEqual(limits.check(now: at(130), lastVoiceAt: at(69.5)), .silenceCountdown(secondsLeft: 30), "重新倒數滿 30 秒")
        XCTAssertEqual(limits.check(now: at(160), lastVoiceAt: at(69.5)), .stop(.longSilence))
    }

    /// 兩個倒數同時成立：顯示比較快停的那個。
    func testTheSoonerCountdownWins() {
        var limits = RecordingLimits(startedAt: start, maxDuration: 300)
        XCTAssertEqual(limits.check(now: at(250), lastVoiceAt: at(185)), .silenceCountdown(secondsLeft: 30), "安靜 65 秒：30 秒後停 < 上限 50 秒")
        XCTAssertEqual(limits.check(now: at(255), lastVoiceAt: at(254)), .countdown(secondsLeft: 45), "講話了：回到上限倒數")
    }
}
