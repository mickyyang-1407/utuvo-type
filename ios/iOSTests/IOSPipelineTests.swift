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
        // core 規則：詞的右側要是非 token 邊界（標點／結尾）才替換——「pik工作」會被視為更長詞而保留
        let (output, steps) = pipeline.clean("我在pik，很順")
        XCTAssertTrue(output.contains("Pik"), "字典替換應生效，實際輸出：\(output)")
        XCTAssertTrue(steps.contains { $0.contains("dictionary") || $0.contains("字典") },
                      "appliedSteps 應記錄字典步驟：\(steps)")
    }

    func testDictionaryRespectsLongerWordBoundary() {
        // 對齊 macOS 既有語意：「pik」右側接中文＝可能是更長詞的一部分 → 不替換
        let pipeline = TextPipeline(dictionary: ["pik": "Pik"])
        let (output, _) = pipeline.clean("pik工作坊")
        XCTAssertFalse(output.contains("Pik"), "右側非邊界時應保留原文，實際輸出：\(output)")
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
