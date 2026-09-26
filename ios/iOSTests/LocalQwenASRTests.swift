import XCTest
import AVFAudio
@testable import UTUVOTypeiOS

/// 本機 Qwen3-ASR 整合的純邏輯（模型本身要實機 GPU，實機數據在工單 RESEARCH-typeless-speed-accuracy.md）。
final class LocalQwenASRTests: XCTestCase {
    func testOnlyChineseAndEnglishUseQwen() {
        XCTAssertEqual(LocalQwenASR.qwenLanguage(for: "zh-TW"), "Chinese")
        XCTAssertEqual(LocalQwenASR.qwenLanguage(for: "zh-CN"), "Chinese")
        XCTAssertEqual(LocalQwenASR.qwenLanguage(for: "en-US"), "English")
        XCTAssertNil(LocalQwenASR.qwenLanguage(for: "ja-JP"), "其他語言照舊用 Apple")
    }

    /// 實機 Qwen 會吐簡體（「麻烦你把…」）；繁中要轉回台灣用字。
    func testSimplifiedOutputBecomesTaiwanTraditional() {
        XCTAssertEqual(LocalQwenASR.clean("麻烦你把授权金钥寄到我的信箱。", language: "zh-TW"), "麻煩你把授權金鑰寄到我的信箱。")
        XCTAssertEqual(LocalQwenASR.clean("  send the stems  ", language: "en-US"), "send the stems")
        XCTAssertNil(LocalQwenASR.clean("   ", language: "zh-TW"))
        XCTAssertEqual(LocalQwenASR.clean("麻烦", language: "zh-CN"), "麻烦", "簡中使用者不轉")
    }

    func testLoopGuardAndTokenCap() {
        XCTAssertTrue(LocalQwenASR.looksLooping("有 T O V O " + String(repeating: "T O ", count: 40), seconds: 5))
        XCTAssertFalse(LocalQwenASR.looksLooping("明天下午我們在錄音室對 Atmos 母帶，記得帶 ADM 檔案。", seconds: 6))
        XCTAssertFalse(LocalQwenASR.looksLooping("哈哈哈哈好啊", seconds: 2))
        XCTAssertEqual(LocalQwenASR.tokenCap(2), 256)
        XCTAssertGreaterThanOrEqual(LocalQwenASR.tokenCap(177), 177 * 8, "上限依整段長度，長段落不能被截尾")
    }

    /// 逾時要準時回 nil，不能等卡住的推論（MLX 推論不能中途取消）。
    func testRaceReturnsNilOnTimeoutWithoutWaiting() async {
        let start = Date()
        let value: String? = await LocalQwenASR.race(.milliseconds(100)) {
            try? await Task.sleep(for: .seconds(3)); return "late"
        }
        XCTAssertNil(value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
        let fast: String? = await LocalQwenASR.race(.seconds(2)) { "ok" }
        XCTAssertEqual(fast, "ok")
    }

    /// 48 kHz 立體聲麥克風 → 16 kHz 單聲道；沒啟用時一個樣本都不存。
    func testAccumulatorResamplesAndHonoursEnabled() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for ch in 0..<2 { for i in 0..<48_000 { buffer.floatChannelData![ch][i] = sin(Float(i) * 0.05) * 0.5 } }
        let acc = PCMAccumulator()
        acc.reset(enabled: false)
        acc.append(buffer)
        XCTAssertTrue(acc.snapshot.isEmpty)
        acc.reset(enabled: true)
        acc.append(buffer)
        XCTAssertEqual(Double(acc.snapshot.count), 16_000, accuracy: 40, "1 秒 48 kHz → 16000 個 16 kHz 樣本（含轉換器尾巴）")
        XCTAssertGreaterThan(acc.snapshot.map(abs).max() ?? 0, 0.1, "不是一段靜音")
    }

    @MainActor
    func testDownloadedMarkerIsRequired() throws {
        // 模擬器永遠不支援；實機只有 .complete 存在才算已下載（中斷的半套模型不能拿來用）。
        #if targetEnvironment(simulator)
        let asr = LocalQwenASR.shared
        XCTAssertEqual(asr.state, .unsupported)
        XCTAssertFalse(asr.isReady)
        #endif
        XCTAssertTrue(LocalQwenASR.cacheDirectory.path.contains("Application Support/QwenASR"))
    }
}

/// 2026-09-24：iOS 26.4 起無法自動跳回原 App → 讓使用者選更長的鍵盤語音工作階段，少跳幾次。
final class KeyboardSessionLengthTests: XCTestCase {
    func testUserChosenSessionLength() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "session-length-\(UUID().uuidString)"))
        XCTAssertEqual(VoiceBridge.userIdleTimeout(defaults), VoiceBridge.defaultIdleTimeout, "沒設定＝3 分鐘")
        defaults.set(30, forKey: VoiceBridge.sessionMinutesKey)
        XCTAssertEqual(VoiceBridge.userIdleTimeout(defaults), 30 * 60)
        defaults.set(7, forKey: VoiceBridge.sessionMinutesKey)
        XCTAssertEqual(VoiceBridge.userIdleTimeout(defaults), VoiceBridge.defaultIdleTimeout, "不在選項裡的值不採用")
    }
}
