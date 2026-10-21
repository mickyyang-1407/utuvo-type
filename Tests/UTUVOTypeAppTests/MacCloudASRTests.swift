import XCTest
import UTUVOTypeCore
@testable import UTUVOTypeApp

/// Mac 雲端辨識（Groq Whisper）：請求格式同 iOS、失敗回退、幻覺把關、簡轉繁。不碰網路與真 Keychain。
final class MacCloudASRTests: XCTestCase {
    /// 1 秒安靜＋1 秒 440 Hz＋1 秒安靜的 16 kHz PCM16。
    private func pcm(seconds quietHead: Double = 1, voice: Double = 1, quietTail: Double = 1) -> Data {
        var data = Data()
        func append(_ v: Int16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        for _ in 0..<Int(quietHead * 16_000) { append(0) }
        for i in 0..<Int(voice * 16_000) { append(Int16(sin(Double(i) * 2 * .pi * 440 / 16_000) * 8_000)) }
        for _ in 0..<Int(quietTail * 16_000) { append(0) }
        return data
    }

    private func groq(_ text: String, status: Int = 200) -> MockCleanupTransport {
        let transport = MockCleanupTransport()
        transport.register(host: "api.groq.com", status: status, bodyJSON: ["text": text])
        return transport
    }

    func testRequestMatchesIOSShapeAndTrimsSilence() async throws {
        let transport = groq("這次在 Pro Tools 上混音")
        let outcome = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: ["Dolby Atmos", "Pro Tools"],
                                                   outputScript: .traditional, key: "fake-groq-key", transport: transport)
        XCTAssertEqual(outcome, .ok("這次在 Pro Tools 上混音"))
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-groq-key")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("whisper-large-v3"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(body.contains("以下是繁體中文（台灣）的語音。常用詞：Dolby Atmos、Pro Tools"))
        // 3 秒錄音剪成 1 秒聲音＋頭尾各 0.3 秒 → WAV 約 1.6 秒（51 KB），不是 3 秒（96 KB）。
        let bytes = try XCTUnwrap(request.httpBody).count
        XCTAssertLessThan(bytes, 60_000)
        XCTAssertGreaterThan(bytes, 45_000)
    }

    func testOutroHallucinationDroppedAndAllHallucinationRejected() async {
        let kept = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                key: "k", transport: groq("明天下午三點開會。謝謝大家收看！"))
        XCTAssertEqual(kept, .ok("明天下午三點開會。"))
        let only = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                key: "k", transport: groq("謝謝大家收看"))
        XCTAssertEqual(only, .failed("empty"), "整段都是幻覺＝退回本機辨識")
    }

    func testSimplifiedOutputConvertedToTaiwanTraditional() async {
        let outcome = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                   key: "k", transport: groq("我们回家吧﹐软件更新了"))
        XCTAssertEqual(outcome, .ok("我們回家吧，軟體更新了"), "OpenCC 詞級轉換＋台灣用語＋小寫標點")
    }

    func testFailuresFallBack() async {
        let http = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                key: "k", transport: groq("x", status: 429))
        XCTAssertEqual(http, .failed("http:429"))
        let offline = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                   key: "k", transport: MockCleanupTransport())
        XCTAssertEqual(offline, .failed("transport"))
        let noKey = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                 key: "", transport: groq("x"))
        XCTAssertEqual(noKey, .skipped("no-key"))
        let japanese = await MacCloudASR.transcribe(pcm16: pcm(), language: "ja", hotwords: [], outputScript: .traditional,
                                                    key: "k", transport: groq("x"))
        XCTAssertEqual(japanese, .skipped("language"))
        let tiny = await MacCloudASR.transcribe(pcm16: Data(count: 2_000), language: "zh-TW", hotwords: [],
                                                outputScript: .traditional, key: "k", transport: groq("x"))
        XCTAssertEqual(tiny, .skipped("too-short"))
    }

    func testLoopingOutputRejected() async {
        let loop = String(repeating: "TO ", count: 20)
        let outcome = await MacCloudASR.transcribe(pcm16: pcm(), language: "zh-TW", hotwords: [], outputScript: .traditional,
                                                   key: "k", transport: groq(loop))
        XCTAssertEqual(outcome, .failed("empty"))
    }

    // MARK: - 停頓預先處理

    private func chunks(_ data: Data, size: Int = 3_200) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min(data.count, $0 + size)) }
    }

    func testPauseDetectorFiresOnceAfterSpeechThenPause() {
        var detector = MacCloudASR.PauseDetector()
        let fired = chunks(pcm(seconds: 0.5, voice: 1, quietTail: 1)).map { detector.feed($0) }
        XCTAssertEqual(fired.filter { $0 }.count, 1, "講完停 0.45 秒觸發一次，之後一直安靜不再觸發")
        // 觸發點在講完後約 0.45 秒：開頭 0.5 秒安靜＋1 秒聲音＋0.45 秒 ≈ 1.95 秒 → 第 20 格（0.1 秒一格）。
        XCTAssertEqual(fired.firstIndex(of: true), 19)
    }

    func testPauseDetectorIgnoresLeadingSilenceAndShortPauses() {
        var detector = MacCloudASR.PauseDetector()
        XCTAssertFalse(chunks(pcm(seconds: 2, voice: 0, quietTail: 0)).contains { detector.feed($0) }, "還沒講話不算停頓")
        var short = MacCloudASR.PauseDetector()
        XCTAssertFalse(chunks(pcm(seconds: 0, voice: 1, quietTail: 0.3)).contains { short.feed($0) }, "0.3 秒換氣不算")
    }

    func testPauseDetectorCapsTriggers() {
        var detector = MacCloudASR.PauseDetector()
        var count = 0
        for _ in 0..<5 { count += chunks(pcm(seconds: 0, voice: 0.5, quietTail: 0.6)).filter { detector.feed($0) }.count }
        XCTAssertEqual(count, 3, "一次錄音最多先處理 3 次")
    }

    func testIsQuietAfterOffset() {
        let audio = pcm(seconds: 0, voice: 1, quietTail: 1)
        XCTAssertTrue(MacCloudASR.isQuiet(audio, from: 32_000), "聲音之後只剩安靜")
        XCTAssertFalse(MacCloudASR.isQuiet(audio, from: 16_000), "後面還有聲音")
        XCTAssertTrue(MacCloudASR.isQuiet(audio, from: audio.count))
    }

    func testEnvironmentKeyWins() {
        XCTAssertEqual(MacCloudASR.key(environment: ["UTUVO_TYPE_GROQ_API_KEY": " env-key \n"]), "env-key")
    }

    func testPCM16Decoding() {
        var data = Data()
        for v: Int16 in [0, 16_384, -32_768] { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        XCTAssertEqual(MacCloudASR.samples(fromPCM16: data), [0, 0.5, -1])
    }

    @MainActor
    func testPreferenceDefaultsOffAndPersists() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        XCTAssertFalse(prefs.cloudASREnabled, "雲端要上傳錄音，預設關")
        prefs.cloudASREnabled = true
        XCTAssertTrue(AppPreferences(isolation: context).cloudASREnabled)
    }
}
