import XCTest
@testable import UTUVOTypeiOS

/// 鍵盤 ↔ 主 app 語音橋接的純邏輯。
final class VoiceBridgeTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func state(_ phase: VoiceBridge.State.Phase, heartbeatAgo: TimeInterval = 0, id: UUID? = nil,
                       partial: String = "", final: String? = nil, error: String? = nil) -> VoiceBridge.State {
        VoiceBridge.State(phase: phase, heartbeat: now.addingTimeInterval(-heartbeatAgo), commandID: id,
                          partial: partial, final: final, error: error)
    }

    // MARK: 活著沒

    func testFreshHeartbeatIsAliveStaleIsNot() {
        XCTAssertTrue(VoiceBridge.isAlive(state(.ready, heartbeatAgo: 1), now: now))
        XCTAssertFalse(VoiceBridge.isAlive(state(.ready, heartbeatAgo: 10), now: now), "主 app 被系統收掉後心跳停")
        XCTAssertFalse(VoiceBridge.isAlive(nil, now: now), "從沒開過工作階段")
    }

    func testEndedPhaseIsNeverAliveEvenWithFreshHeartbeat() {
        XCTAssertFalse(VoiceBridge.isAlive(state(.ended, heartbeatAgo: 0), now: now))
    }

    /// 鐘差或未來時間戳（例如使用者改時間）不能讓死掉的工作階段看起來永遠活著。
    func testFarFutureHeartbeatIsNotAlive() {
        XCTAssertFalse(VoiceBridge.isAlive(state(.ready, heartbeatAgo: -3600), now: now))
    }

    func testStartPlan() {
        XCTAssertEqual(VoiceBridge.startPlan(state: state(.ready, heartbeatAgo: 1), now: now), .sendCommand)
        XCTAssertEqual(VoiceBridge.startPlan(state: state(.ready, heartbeatAgo: 60), now: now), .openApp)
        XCTAssertEqual(VoiceBridge.startPlan(state: nil, now: now), .openApp)
    }

    // MARK: 指令

    func testCommandFreshness() {
        let fresh = VoiceBridge.Command(action: .start, id: UUID(), language: "zh-TW", sentAt: now.addingTimeInterval(-2))
        let stale = VoiceBridge.Command(action: .start, id: UUID(), language: "zh-TW", sentAt: now.addingTimeInterval(-120))
        XCTAssertTrue(VoiceBridge.isFresh(fresh, now: now))
        XCTAssertFalse(VoiceBridge.isFresh(stale, now: now), "很久以後才打開 app，不該突然開始錄音")
    }

    // MARK: 結果投遞

    func testDeliveryOnlyForMyCommand() {
        let mine = UUID(), other = UUID()
        XCTAssertEqual(VoiceBridge.delivery(for: state(.recording, id: other, partial: "別人的"), expecting: mine), .ignore)
        XCTAssertEqual(VoiceBridge.delivery(for: state(.recording, id: mine, partial: "我的"), expecting: nil), .ignore)
    }

    func testDeliveryPartialFinalFailed() {
        let id = UUID()
        XCTAssertEqual(VoiceBridge.delivery(for: state(.recording, id: id, partial: "今天"), expecting: id), .partial("今天"))
        XCTAssertEqual(VoiceBridge.delivery(for: state(.finishing, id: id, partial: "今天下午"), expecting: id), .partial("今天下午"))
        XCTAssertEqual(VoiceBridge.delivery(for: state(.ready, id: id, partial: "x", final: "今天下午三點"), expecting: id), .final("今天下午三點", translated: nil))
        XCTAssertEqual(VoiceBridge.delivery(for: state(.failed, id: id, error: "沒有麥克風權限"), expecting: id), .failed("沒有麥克風權限"))
    }

    /// 空字串 final（使用者沒講話就按停止）也要投遞，鍵盤才會收起錄音狀態。
    func testEmptyFinalIsStillDelivered() {
        let id = UUID()
        XCTAssertEqual(VoiceBridge.delivery(for: state(.ready, id: id, final: ""), expecting: id), .final("", translated: nil))
    }

    /// 2026-09-17 模擬器抓到：fail() 之後心跳把 phase 蓋回 ready，鍵盤回來讀到 ready＋error 卻當成「沒事」而卡在錄音中。
    func testErrorSurvivesHeartbeatRewritingPhaseToReady() {
        let id = UUID()
        XCTAssertEqual(VoiceBridge.delivery(for: state(.ready, id: id, error: "這個語言的辨識器目前不可用"), expecting: id),
                       .failed("這個語言的辨識器目前不可用"))
    }

    func testFinalCarriesAppSideTranslation() {
        let id = UUID()
        var s = state(.ready, id: id, final: "明天見")
        s.translated = "See you tomorrow"
        XCTAssertEqual(VoiceBridge.delivery(for: s, expecting: id), .final("明天見", translated: "See you tomorrow"))
    }

    /// 舊版主 app 寫的指令檔沒有 translateTo 欄位，新版要讀得進來。
    func testCommandDecodesWithoutTranslateTo() throws {
        let json = #"{"action":"start","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","language":"zh-TW","sentAt":800000000}"#
        let cmd = try JSONDecoder().decode(VoiceBridge.Command.self, from: Data(json.utf8))
        XCTAssertNil(cmd.translateTo)
    }

    func testTranslatorLanguageMapping() {
        XCTAssertEqual(FastTranslator.languageIdentifier(forDictation: "zh-TW"), "zh-Hant")
        XCTAssertEqual(FastTranslator.languageIdentifier(forDictation: "zh-CN"), "zh-Hans")
        XCTAssertEqual(FastTranslator.languageIdentifier(forDictation: "en-US"), "en")
        XCTAssertEqual(FastTranslator.languageIdentifier(forDictation: "ja-JP"), "ja")
    }

    func testReadyWithoutFinalIsIgnored() {
        let id = UUID()
        XCTAssertEqual(VoiceBridge.delivery(for: state(.ready, id: id), expecting: id), .ignore)
    }

    // MARK: 閒置

    func testIdleTimeoutOnlyWhenReady() {
        let long = now.addingTimeInterval(-400)
        XCTAssertTrue(VoiceBridge.shouldEndIdleSession(phase: .ready, lastActivity: long, now: now, timeout: 300))
        XCTAssertFalse(VoiceBridge.shouldEndIdleSession(phase: .recording, lastActivity: long, now: now, timeout: 300), "錄音中不能因為閒置被關")
        XCTAssertFalse(VoiceBridge.shouldEndIdleSession(phase: .ready, lastActivity: now.addingTimeInterval(-10), now: now, timeout: 300))
    }

    // MARK: URL／檔案

    func testSessionURLRoundTrip() {
        let id = UUID()
        let url = VoiceBridge.sessionURL(language: "zh-TW", commandID: id)
        XCTAssertEqual(url.scheme, "utuvotype")
        let parsed = VoiceBridge.parseSessionURL(url)
        XCTAssertEqual(parsed?.language, "zh-TW")
        XCTAssertEqual(parsed?.commandID, id)
    }

    func testSessionURLCarriesHostBundleForAutoReturn() {
        let url = VoiceBridge.sessionURL(language: "zh-TW", commandID: UUID(), returnTo: "jp.naver.line")
        XCTAssertEqual(VoiceBridge.parseSessionURL(url)?.returnTo, "jp.naver.line")
    }

    /// URL 可被任何 app 觸發：回跳目標只接受 bundle id 形狀，其他一律丟掉。
    func testReturnTargetRejectsNonBundleStrings() {
        for bad in ["", "safari", "https://evil.example", "a..b", ".com.apple", "com.apple.", "com apple.x", String(repeating: "a.", count: 100)] {
            XCTAssertFalse(VoiceBridge.isPlausibleBundleID(bad), bad)
        }
        let raw = URL(string: "utuvotype://voice?lang=zh-TW&return=https://evil.example")!
        XCTAssertNil(VoiceBridge.parseSessionURL(raw)?.returnTo)
        XCTAssertTrue(VoiceBridge.isPlausibleBundleID("com.apple.mobilesafari"))
    }

    func testParseRejectsForeignURLs() {
        XCTAssertNil(VoiceBridge.parseSessionURL(URL(string: "https://example.com/voice?lang=zh-TW")!))
        XCTAssertNil(VoiceBridge.parseSessionURL(URL(string: "utuvotype://other?lang=zh-TW")!))
        XCTAssertNil(VoiceBridge.parseSessionURL(URL(string: "utuvotype://voice")!), "沒有語言不啟動")
    }

    func testStateFileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let s = state(.recording, id: UUID(), partial: "明天下午三點")
        VoiceBridge.write(s, name: VoiceBridge.stateFile, in: dir)
        XCTAssertEqual(VoiceBridge.read(VoiceBridge.State.self, name: VoiceBridge.stateFile, in: dir), s)
    }
}
