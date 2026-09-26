import XCTest
@testable import UTUVOTypeCore
@testable import UTUVOTypeiOS

/// iOS 煙霧測試：core normalizer 在 iOS runtime 的真實行為。
/// macOS 測試線（repo 檔案依賴）不搬過來——那邊照舊在 Mac 上跑。
final class IOSPipelineTests: XCTestCase {
    func testNormalizerRunsOnIOS() {
        let pipeline = TextPipeline(dictionary: [:])
        let (output, _) = pipeline.clean("嗯我今天下午三點開會，不是三點，是四點。")
        XCTAssertFalse(output.isEmpty, "normalizer 不該把整句清空")
    }

    func testDictionaryReplacementOnIOS() {
        let pipeline = TextPipeline(dictionary: ["pik": "Pik"])
        let (output, steps) = pipeline.clean("我在pik，很順")
        XCTAssertTrue(output.contains("Pik"), "字典替換應生效，實際輸出：\(output)")
        XCTAssertTrue(steps.contains { $0.contains("dictionary") || $0.contains("字典") },
                      "appliedSteps 應記錄字典步驟：\(steps)")
    }

    func testDictionaryRespectsLongerWordBoundary() {
        // 2026-09-19 core 規則改版（13194f8）：英文詞緊貼中文也替換（辨識器常輸出「pik工作坊」）；
        // 右側接的是英數字才算更長的詞（pika）→ 不替換。
        let pipeline = TextPipeline(dictionary: ["pik": "Pik"])
        XCTAssertTrue(pipeline.clean("pik工作坊").output.contains("Pik"), "英文詞後面接中文要替換")
        let (output, _) = pipeline.clean("pika工作坊")
        XCTAssertFalse(output.contains("Pik"), "更長的英文詞要保留原文，實際輸出：\(output)")
    }

    /// 2026-09-25 量測：設定頁「新增詞彙」存的是「詞 → 空字串」，英文專名修正卻只看輸出寫法，自己加的詞從沒被用上。
    func testVocabularyTermsReachLatinFixer() {
        let dictionary = ["LemonSqueezy": "", "阿特摩斯": "Atmos", "苑涵": ""]
        let terms = VocabularyPacks.latinTermsForFixer(dictionary: dictionary)
        XCTAssertTrue(terms.contains("LemonSqueezy"), "詞彙模式的詞要進比對表：\(terms.prefix(5))")
        XCTAssertTrue(terms.contains("Atmos"), "替換模式用輸出寫法")
        XCTAssertFalse(terms.contains("阿特摩斯"), "替換模式不用聽錯的寫法")
        XCTAssertFalse(terms.contains("苑涵"), "沒有拉丁字母的詞不進英文專名表")
        let output = TextPipeline(dictionary: dictionary, latinTerms: terms).clean("麻煩你把 lemon squeezy 的授權寄給我").output
        XCTAssertTrue(output.contains("LemonSqueezy"), "實際輸出：\(output)")
    }

    func testFillerRemovalOnIOS() {
        let pipeline = TextPipeline(dictionary: [:])
        let (output, steps) = pipeline.clean("嗯就是那個會議啦")
        XCTAssertTrue(steps.contains { $0.lowercased().contains("filler") },
                      "應套用語助詞過濾步驟：\(steps)")
        _ = output
    }

    func testHistoryStoreRoundTrip() {
        // 用暫存目錄驗證 JSON round-trip（不碰 App Group）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HistoryStore(defaults: nil)
        // HistoryStore 的 fileURL 由 group 決定；這裡只驗 model 編碼不炸
        let record = DictationRecord(raw: "raw 測試", cleaned: "cleaned 測試")
        XCTAssertEqual(record.cleaned, "cleaned 測試")
        let data = try! JSONEncoder().encode([record])
        let decoded = try! JSONDecoder().decode([DictationRecord].self, from: data)
        XCTAssertEqual(decoded.first?.raw, "raw 測試")
        try? FileManager.default.removeItem(at: dir)
        _ = store
    }
}
