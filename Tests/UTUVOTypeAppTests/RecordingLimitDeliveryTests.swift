import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// repair-batch1（2026-10-22）：忘記關麥的保護在 App 這一層——倒數要看得到（選單關著也一樣），
/// 很久沒聲音而自動停下來的那一次不按送出鍵（文字照樣留著）。隔離模式：不開麥克風、不出聲、不碰剪貼簿。
/// repair round 2（主控決定）：倒數**不出聲**——麥克風開著，提示音會被錄進去，還會被當成「有聲音」把安靜倒數
/// 取消掉；開了「錄音時靜音」也聽不到。原本三個「提示音響了幾次」的斷言（1／1／2）改成斷言看得到的狀態
/// （`recordingLimitCountdown` → 錄音球「快停了」），提示音的程式整段拿掉。
@MainActor
final class RecordingLimitDeliveryTests: XCTestCase {
    private func makeModel(_ context: IsolatedContext, autoSubmit: AutoSubmit = .returnKey) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.mode = .fast
        preferences.autoSubmit = autoSubmit
        return AppModel(preferences: preferences)
    }

    private func temporaryRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-type-test-\(UUID().uuidString).caf")
        try Data("synthetic-audio".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 很久沒聲音：倒數（錄音球換成快停了的樣子）→ 停止 → 這一次不按送出鍵，文字照樣寫進歷史；下一次聽寫恢復設定。
    func testLongSilenceStopNeverAutoSubmitsButKeepsTheTranscript() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        model.startRecording(mode: .fast)   // 隔離模式：抓目的地＋脈絡後就停在麥克風前
        XCTAssertEqual(model.effectiveAutoSubmit, .returnKey)

        XCTAssertTrue(model.applyRecordingLimit(.silenceCountdown(secondsLeft: 30), maxDuration: 540))
        XCTAssertTrue(model.applyRecordingLimit(.silenceCountdown(secondsLeft: 29), maxDuration: 540))
        XCTAssertEqual(model.recordingLimitCountdown, .longSilence, "倒數中：錄音球是「快停了」的樣子（不出聲）")
        XCTAssertNotNil(model.recordingLimitNotice)
        XCTAssertFalse(model.applyRecordingLimit(.stop(.longSilence), maxDuration: 540))
        XCTAssertNil(model.recordingLimitCountdown, "停了：錄音球回到原樣")
        XCTAssertEqual(model.effectiveAutoSubmit, .off, "很久沒聲音而停的那一次不送出")
        XCTAssertEqual(model.preferences.autoSubmit, .returnKey, "設定本身不動")
        XCTAssertNil(model.recordingLimitNotice)

        let temp = try temporaryRecording()
        await model.completeSyntheticCapture(audioURL: temp, duration: 90) { ("合成測試文字", nil) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertNil(record.status, "正常完成：文字照樣留著")
        XCTAssertEqual(record.output, "合成測試文字")

        model.startRecording(mode: .fast)
        XCTAssertEqual(model.effectiveAutoSubmit, .returnKey, "只影響那一次")
    }

    /// 到長度上限停止：照 Typeless 照常送出（設定不變）。
    func testMaxDurationStopKeepsTheAutoSubmitSetting() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        model.startRecording(mode: .fast)
        XCTAssertTrue(model.applyRecordingLimit(.countdown(secondsLeft: 60), maxDuration: 295))
        XCTAssertEqual(model.recordingLimitCountdown, .maxDuration)
        XCTAssertFalse(model.applyRecordingLimit(.stop(.maxDuration), maxDuration: 295))
        XCTAssertEqual(model.effectiveAutoSubmit, .returnKey)
    }

    /// 安靜倒數中講話：提示收掉、錄音球回到原樣；之後再倒數＝新的一輪，錄音球再變。
    func testSoundDuringCountdownClearsTheNotice() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        model.startRecording(mode: .fast)
        XCTAssertTrue(model.applyRecordingLimit(.silenceCountdown(secondsLeft: 30), maxDuration: 540))
        XCTAssertNotNil(model.recordingLimitNotice)
        XCTAssertTrue(model.applyRecordingLimit(.none, maxDuration: 540))
        XCTAssertNil(model.recordingLimitNotice, "講話了：倒數取消")
        XCTAssertNil(model.recordingLimitCountdown)
        XCTAssertTrue(model.applyRecordingLimit(.silenceCountdown(secondsLeft: 30), maxDuration: 540))
        XCTAssertEqual(model.recordingLimitCountdown, .longSilence)
        XCTAssertEqual(model.effectiveAutoSubmit, .returnKey, "倒數本身不改送出")
    }

    /// 選單關著、只看得到錄音球時：倒數在錄音球的輔助說明與狀態列圖示的提示文字裡。
    func testCountdownIsSurfacedOnTheOrbAndTheStatusItem() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        let preferences = model.preferences
        model.startRecording(mode: .fast)
        XCTAssertTrue(model.applyRecordingLimit(.countdown(secondsLeft: 42), maxDuration: 540))
        let notice = try XCTUnwrap(model.recordingLimitNotice)
        XCTAssertTrue(notice.contains("42"), notice)

        let orb = OverlayWindowController.accessibilityStatus(isRecording: true, limitNotice: notice, preferences: preferences)
        XCTAssertTrue(orb.contains(notice), orb)
        XCTAssertTrue(orb.hasPrefix(preferences.tr("聆聽中", "Listening")), orb)
        XCTAssertEqual(OverlayWindowController.accessibilityStatus(isRecording: true, limitNotice: nil, preferences: preferences),
                       preferences.tr("聆聽中", "Listening"), "沒倒數時照舊")

        let tip = AppDelegate.statusItemToolTip(isRecording: true, isProcessing: false, statusMessage: "x", limitNotice: notice)
        XCTAssertTrue(tip.contains(notice), tip)
        XCTAssertEqual(AppDelegate.statusItemToolTip(isRecording: true, isProcessing: false, statusMessage: "x", limitNotice: nil),
                       AppBrand.displayName, "沒倒數時照舊")
        XCTAssertEqual(AppDelegate.statusItemToolTip(isRecording: false, isProcessing: true, statusMessage: "整理中", limitNotice: nil),
                       "\(AppBrand.displayName)：整理中", "處理中照舊")
    }

    /// repair round 2：安靜的房間（雜訊地板 0.0005 ≈ −66 dBFS，每秒 8 格 tap）從 60 秒開始倒數，30 秒裡每一秒
    /// 錄音球都是「快停了」、提示文字都在，倒數沒有被打斷，90 秒停、不送出。以前倒數一開始就響一聲：
    /// 喇叭外放時那一聲被麥克風收進下一格（高過 0.002 的門檻）＝「有聲音」，倒數第 1 秒就自己取消、每 61 秒重來一次，
    /// 一直錄到長度上限才停、還照常送出。現在倒數不出聲，錄進去的只有房間本身。
    func testQuietRoomCountdownIsShownOnTheOrbForTheFullThirtySecondsAndStopsAt90() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = makeModel(context)
        model.startRecording(mode: .fast)
        let session = AudioCaptureSession(voiceActivityDetection: false)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var limits = RecordingLimits(startedAt: start)
        var warnedSeconds: [Int] = []
        var stoppedAt: Int?
        for second in 1...200 {
            for tap in 0..<8 {
                _ = session.noteVoiceLevel(rms: 0.0005, at: start.addingTimeInterval(Double(second - 1) + Double(tap) / 8))
            }
            let now = start.addingTimeInterval(Double(second))
            let action = limits.check(now: now, capturedSeconds: Double(second), lastVoiceAt: session.lastSoundActivity)
            let keepWatching = model.applyRecordingLimit(action, maxDuration: RecordingLimits.maxSeconds)
            if OverlayWindowController.showsLimitWarning(isRecording: true, countdown: model.recordingLimitCountdown) {
                warnedSeconds.append(second)
                let notice = try XCTUnwrap(model.recordingLimitNotice, "第 \(second) 秒")
                XCTAssertTrue(OverlayWindowController.accessibilityStatus(isRecording: true, limitNotice: notice,
                                                                          preferences: model.preferences).contains(notice))
            }
            if !keepWatching { stoppedAt = second; break }
        }
        XCTAssertEqual(stoppedAt, 90, "倒數完整 30 秒後停，不是拖到長度上限")
        XCTAssertEqual(warnedSeconds, Array(60...89), "60–89 秒每一秒都看得到「快停了」")
        XCTAssertEqual(model.effectiveAutoSubmit, .off, "很久沒聲音而停：不送出")
        XCTAssertFalse(OverlayWindowController.showsLimitWarning(isRecording: true, countdown: model.recordingLimitCountdown))
    }

    /// 錄音球「快停了」的樣子：只有錄音中、有倒數時；灰度每秒閃一下，減少動態效果時固定（不靠動畫也看得出來）。
    func testOrbWarningStateFollowsTheCountdown() {
        XCTAssertTrue(OverlayWindowController.showsLimitWarning(isRecording: true, countdown: .longSilence))
        XCTAssertTrue(OverlayWindowController.showsLimitWarning(isRecording: true, countdown: .maxDuration))
        XCTAssertFalse(OverlayWindowController.showsLimitWarning(isRecording: true, countdown: nil))
        XCTAssertFalse(OverlayWindowController.showsLimitWarning(isRecording: false, countdown: .maxDuration), "整理中不顯示")
        let samples = stride(from: Float(0), to: 2, by: 0.05).map { VoiceOrbView.warningDim(time: $0, reduceMotion: false) }
        XCTAssertGreaterThanOrEqual(samples.min() ?? 0, 0.4, "閃的時候也一直明顯比平常灰（不會閃回原色）")
        XCTAssertGreaterThan((samples.max() ?? 0) - (samples.min() ?? 0), 0.3, "看得出在閃")
        XCTAssertEqual(VoiceOrbView.warningDim(time: 0, reduceMotion: true), VoiceOrbView.warningDim(time: 0.5, reduceMotion: true),
                       "減少動態效果：固定變灰")
        XCTAssertGreaterThan(VoiceOrbView.warningDim(time: 0.5, reduceMotion: true), 0.3)
    }
}
