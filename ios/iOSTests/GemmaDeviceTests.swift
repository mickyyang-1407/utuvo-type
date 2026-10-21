import XCTest
@testable import UTUVOTypeiOS

/// 真模型量測（Gemma 4 E2B，CPU）。模型 2.5 GB 不進 repo：先放到 App 的
/// `Library/Application Support/Gemma/gemma-4-E2B-it.litertlm`（模擬器用 simctl get_app_container 複製），沒有就跳過。
/// 結果寫到 Documents/gemma-bench.json 並印在 log（GEMMA-BENCH）。
final class GemmaDeviceTests: XCTestCase {
    private let samples = [
        "嗯我們約禮拜三，不是，禮拜四下午三點在公司見，然後我搭到元山站以後再換車，悠悠卡記得先除值。",
        "那個就是說我覺得這個這個混音的低頻有點太多，然後人聲可以再往前一點，嗯，大概這樣。",
        "明天要做三件事，第一個是寄母帶給客戶，第二個是確認 Atmos 的交付規格，第三個是跟 Pro Tools 的 session 備份",
        "你可以幫我查一下明天台北的天氣嗎",
        "我、我想明天，不對，後天寄，然後記得帶硬碟跟耳機",
    ]

    private func requireModel() throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: GemmaCleanup.modelURL.path)[.size] as? Int64) ?? -1
        try XCTSkipUnless(size == GemmaCleanup.bytes, "模型檔不在 \(GemmaCleanup.modelURL.path)")
        if !GemmaCleanup.isVerified { XCTAssertTrue(GemmaCleanup.adoptExistingFile(), "SHA-256 對不上") }
    }

    private let config: @Sendable () -> SmartCleanup.Configuration = { .init(enabled: true, provider: .groq, endpoint: "", model: "", key: "") }

    func testCleansSamplesOnDevice() async throws {
        try requireModel()
        let loadStart = Date()
        try await GemmaEngine.shared.load()
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        XCTAssertTrue(GemmaCleanup.isPrepared, "載入成功後要留下準備好的記號")
        var rows: [[String: Any]] = []
        for text in samples {
            let start = Date()
            let raw = RawBox()
            let out = await SmartCleanup.clean(text, language: "zh-TW", timeout: 120, configuration: config, onDevice: { system, user in
                let r = try await GemmaEngine.shared.complete(system: system, user: user)
                raw.set(r)
                return r
            }, log: { _, _, _, _ in })
            rows.append(["input": text, "ms": Int(Date().timeIntervalSince(start) * 1000), "output": out ?? NSNull(), "raw": raw.get() ?? NSNull()])
        }
        let report: [String: Any] = ["loadMs": loadMs, "engineLoadMs": await GemmaEngine.shared.lastLoadMs, "results": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted])
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try data.write(to: docs.appendingPathComponent("gemma-bench.json"))
        print("GEMMA-BENCH", String(data: data, encoding: .utf8) ?? "")
        XCTAssertNotNil(rows[4]["output"] as? String, "改口那句應該整理成功")
        // 不代答：要嘛被把關擋下（Pixel 實測模型想代答），要嘛只整理原句（模擬器這次只補問號）。
        if let weather = rows[3]["output"] as? String {
            XCTAssertTrue(weather.hasPrefix("你可以幫我查一下明天台北的天氣"), "不能變成回答：\(weather)")
        }
    }

    /// 逾時（CleanupBudget 取消 Task）→ 模型被叫停，下一句照常完成。
    func testCancelMidGenerationThenNextWorks() async throws {
        try requireModel()
        try await GemmaEngine.shared.load()
        let long = samples.joined(separator: "，")
        for round in 0..<2 {
            let before = await GemmaEngine.shared.inferenceCount()
            let start = Date()
            let cut = await SmartCleanup.clean(long, language: "zh-TW", timeout: 1.0, configuration: config,
                                               onDevice: { try await GemmaEngine.shared.complete(system: $0, user: $1) },
                                               log: { _, _, _, _ in })
            XCTAssertNil(cut, "第 \(round) 輪應該逾時")
            let next = await SmartCleanup.clean(samples[4], language: "zh-TW", timeout: 60, configuration: config,
                                                onDevice: { try await GemmaEngine.shared.complete(system: $0, user: $1) },
                                                log: { _, _, _, _ in })
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("GEMMA-BENCH cancel round=\(round) total ms=\(ms) next=\(next ?? "nil")")
            XCTAssertNotNil(next, "取消後下一句要能完成")
            let after = await GemmaEngine.shared.inferenceCount()
            XCTAssertEqual(after - before, 2)
        }
    }
}

private final class RawBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

extension GemmaDeviceTests {
    /// luna-review iOS r1：推論中刪除 → 先停推論、等引擎放掉才刪檔；不閃退、刪完回到未下載。
    /// 會刪掉模型（2.5 GB），所以只在帶 GEMMA_ALLOW_DELETE=1 時跑（跑完要重新放模型）。
    func testDeleteDuringInferenceIsSafe() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_ALLOW_DELETE"] == "1", "會刪模型，手動才跑")
        try requireModel()
        try await GemmaEngine.shared.load()
        let long = String(repeating: "那個就是說我覺得這個混音的低頻有點太多，", count: 6)
        let running = Task { try? await GemmaEngine.shared.complete(system: SmartCleanup.instructions, user: long) }
        try await Task.sleep(for: .milliseconds(300))
        await GemmaCleanup.shared.delete()
        _ = await running.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: GemmaCleanup.modelURL.path))
        let state = await GemmaCleanup.shared.state
        // 有 Apple Intelligence 的模擬器刪完是「不提供」；沒有的機型回到「未下載」。
        XCTAssertEqual(state, GemmaCleanup.isOffered ? .notDownloaded : .unsupported)
    }
}

extension GemmaDeviceTests {
    /// 真的從 Hugging Face 下載 2.5 GB → 驗 SHA-256 → 第一次準備 → ready。只在帶 GEMMA_DOWNLOAD=1 時跑。
    @MainActor
    func testRealDownloadVerifiesAndPrepares() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GEMMA_DOWNLOAD"] == "1", "要下載 2.5 GB，手動才跑")
        KeyboardPresence.defaults.set(true, forKey: OnDeviceAssistant.debugManualDisableKey)   // 模擬器有 Apple Intelligence
        defer { KeyboardPresence.defaults.removeObject(forKey: OnDeviceAssistant.debugManualDisableKey) }
        let gemma = GemmaCleanup.shared
        await gemma.delete()
        XCTAssertEqual(gemma.state, .notDownloaded)
        let start = Date()
        gemma.download()
        var seen: Set<String> = []
        while Date().timeIntervalSince(start) < 1800 {
            switch gemma.state {
            case .downloading: seen.insert("downloading")
            case .verifying: seen.insert("verifying")
            case .preparing: seen.insert("preparing")
            case .ready: seen.insert("ready")
            case .failed(let reason): XCTFail("失敗：\(reason)"); return
            default: break
            }
            if gemma.state == .ready { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("GEMMA-BENCH download states=\(seen.sorted()) seconds=\(Int(Date().timeIntervalSince(start)))")
        XCTAssertEqual(gemma.state, .ready)
        XCTAssertTrue(GemmaCleanup.isUsable)
        XCTAssertTrue(seen.contains("downloading"))
    }
}
