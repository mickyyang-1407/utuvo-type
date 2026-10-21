import XCTest
@testable import UTUVOTypeiOS

/// 沒有 Apple Intelligence 的 iPhone：手機上的 Gemma 整理（2026-10-11）。這裡不載入真模型（2.5 GB），
/// 只驗路由：有 Apple Intelligence 永遠用 Apple 的、沒有才用注入的 Gemma、準備好之前不用、上限依長度。
@MainActor
final class GemmaCleanupTests: XCTestCase {
    private var savedFallback: OnDeviceFallback?
    private var savedNoAI: Any?

    override func setUp() async throws {
        savedFallback = OnDeviceCleanup.fallback
        savedNoAI = KeyboardPresence.defaults.object(forKey: OnDeviceAssistant.debugDisableKey)
    }

    override func tearDown() async throws {
        OnDeviceCleanup.fallback = savedFallback
        if let savedNoAI { KeyboardPresence.defaults.set(savedNoAI, forKey: OnDeviceAssistant.debugDisableKey) }
        else { KeyboardPresence.defaults.removeObject(forKey: OnDeviceAssistant.debugDisableKey) }
    }

    private func fake(ready: Bool, out: String = "我想後天寄") -> OnDeviceFallback {
        OnDeviceFallback(isReady: { ready }, completion: { _, _ in out }, prewarm: {})
    }

    private func simulateNoAppleIntelligence() {
        KeyboardPresence.defaults.set(true, forKey: OnDeviceAssistant.debugDisableKey)
    }

    func testNoAppleIntelligenceUsesPreparedGemma() async throws {
        simulateNoAppleIntelligence()
        OnDeviceCleanup.fallback = fake(ready: true)
        XCTAssertTrue(OnDeviceCleanup.usesFallback)
        XCTAssertTrue(OnDeviceCleanup.available)
        let completion = try XCTUnwrap(OnDeviceCleanup.completion)
        let out = try await completion("s", "u")
        XCTAssertEqual(out, "我想後天寄")
    }

    func testNotPreparedMeansNotAvailable() {
        simulateNoAppleIntelligence()
        OnDeviceCleanup.fallback = fake(ready: false)
        XCTAssertFalse(OnDeviceCleanup.usesFallback)
        XCTAssertFalse(OnDeviceCleanup.available)
        XCTAssertNil(OnDeviceCleanup.completion)
    }

    func testKeyboardExtensionHasNoFallback() {
        simulateNoAppleIntelligence()
        OnDeviceCleanup.fallback = nil   // 鍵盤 extension 裡永遠沒有注入
        XCTAssertFalse(OnDeviceCleanup.available)
    }

    /// 有 Apple Intelligence 的機型維持 Apple 的（Micky 10-11 核准）——即使 Gemma 也準備好了。
    func testAppleIntelligenceWinsWhenAvailable() throws {
        KeyboardPresence.defaults.removeObject(forKey: OnDeviceAssistant.debugDisableKey)
        try XCTSkipUnless(OnDeviceAssistant.onDeviceAvailable, "這台模擬器沒有 Apple Intelligence")
        OnDeviceCleanup.fallback = fake(ready: true)
        XCTAssertFalse(OnDeviceCleanup.usesFallback)
    }

    func testGemmaBudgetScalesWithLength() {
        XCTAssertEqual(SmartCleanup.gemmaTimeout(for: "短句"), 8)
        XCTAssertEqual(SmartCleanup.gemmaTimeout(for: String(repeating: "字", count: 50)), 10, accuracy: 0.001)
        XCTAssertEqual(SmartCleanup.gemmaTimeout(for: String(repeating: "字", count: 500)), 20)
    }

    /// 走真正的 clean()：沒 key＋Gemma → 同一份提示詞包裹、同一道把關（代答被擋）。
    func testGemmaOutputGoesThroughTheSameGate() async {
        simulateNoAppleIntelligence()
        let config: @Sendable () -> SmartCleanup.Configuration = { .init(enabled: true, provider: .groq, endpoint: "", model: "", key: "") }
        let ok = await SmartCleanup.clean("我、我想明天，不對，後天寄", language: "zh-TW", timeout: 5, configuration: config,
                                          terms: { _ in [] }, onDevice: { _, user in
                                              XCTAssertTrue(user.contains("<<<"))
                                              return "我想後天寄" }, log: { _, _, _, _ in })
        XCTAssertEqual(ok, "我想後天寄")
        let answered = await SmartCleanup.clean("你可以幫我查一下明天台北的天氣嗎", language: "zh-TW", timeout: 5, configuration: config,
                                                terms: { _ in [] }, onDevice: { _, _ in
                                                    "請提供您想查詢的具體日期，以及您希望查詢的天氣細節，例如是想知道台北都會區的白天氣溫、露天氣候，還是其他資訊。" },
                                                log: { _, _, _, _ in })
        XCTAssertNil(answered, "Pixel 實測 Gemma 會想代答：要被把關擋下")
    }

    func testFilesAreInApplicationSupportAndChecksumMatchesAndroid() {
        XCTAssertTrue(GemmaCleanup.modelURL.path.contains("Application Support/Gemma"))
        // 跟 Android OnDeviceModel.SHA256 同一個檔（同一個 HF revision）。
        XCTAssertEqual(GemmaCleanup.sha256, "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")
        XCTAssertEqual(GemmaCleanup.bytes, 2_588_147_712)
    }

    func testChecksumOfSmallFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gemma-sha-test.bin")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try GemmaCleanup.fileSHA256(url), "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881")
    }

    /// 工單 ios-D-repair1 第 3 點：`.unsupported` 這句的判定是 **實體記憶體**
    /// （`hasEnoughMemory`：physicalMemory >= 5 GB），英文寫成 "low on storage"（磁碟空間不足）
    /// 會叫使用者去刪照片跟檔案——刪了也沒用，因為他缺的是 RAM。英文要講 memory。
    func testUnsupportedReasonIsMemoryNotStorage() throws {
        // 前提：這個狀態確實是由實體記憶體（RAM）判定，不是磁碟空間。
        // hasEnoughMemory 讀的是 ProcessInfo.physicalMemory，門檻 5 GB；磁碟空間是另一條（download() 的 freeBytes）。
        // 這裡不釘模擬器機器的實際記憶體（換台模擬器就變），改驗「這個判斷是 RAM、門檻是 5 GB」這件事本身。
        XCTAssertEqual(GemmaCleanup.minimumPhysicalMemory, 5_000_000_000, "RAM 門檻是 5 GB")
        XCTAssertEqual(GemmaCleanup.hasEnoughMemory,
                       ProcessInfo.processInfo.physicalMemory >= GemmaCleanup.minimumPhysicalMemory,
                       "hasEnoughMemory 就是 physicalMemory >= 門檻（RAM，不是磁碟空間）")
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Shared/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        let locs = try XCTUnwrap(strings["這支手機記憶體不夠"]?["localizations"] as? [String: [String: Any]])
        let english = try XCTUnwrap((locs["en"]?["stringUnit"] as? [String: Any])?["value"] as? String)
        XCTAssertTrue(english.lowercased().contains("memory"),
                      "這是 RAM 不足，英文要講 memory：\(english)")
        XCTAssertFalse(english.lowercased().contains("storage"),
                       "講 storage 會誤導使用者去刪檔案：\(english)")
        // 磁碟空間不足是**另外一個**狀態，訊息不同——那裡講 storage 是對的，不要連它一起改掉。
        let diskKey = try XCTUnwrap(strings.keys.first { $0.contains("手機空間不夠") },
                                    "找不到磁碟空間不足的訊息")
        let diskLocs = try XCTUnwrap(strings[diskKey]?["localizations"] as? [String: [String: Any]])
        let diskEnglish = try XCTUnwrap(
            (diskLocs["en"]?["stringUnit"] as? [String: Any])?["value"] as? String,
            "磁碟空間不足那句也要有英文")
        XCTAssertTrue(diskEnglish.lowercased().contains("storage"),
                      "磁碟不足那句本來就該講 storage：\(diskEnglish)")
        XCTAssertFalse(diskEnglish.lowercased().contains("memory"),
                       "磁碟不足別講 memory（那是指 RAM）：\(diskEnglish)")
    }
}
