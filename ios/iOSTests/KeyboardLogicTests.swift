import XCTest
import UIKit
@testable import UTUVOTypeiOS

/// 鍵盤純邏輯：模式判定、送出鍵文案、用量統計。
final class KeyboardLogicTests: XCTestCase {
    func testModeDecision() {
        XCTAssertEqual(KeyboardMode.decide(selectedText: nil, translateTarget: nil), .dictate)
        XCTAssertEqual(KeyboardMode.decide(selectedText: "   ", translateTarget: nil), .dictate)
        XCTAssertEqual(KeyboardMode.decide(selectedText: "hello", translateTarget: nil), .edit(selection: "hello"))
        let ja = TranslationTarget.all.first { $0.code == "ja" }!
        // 剛長按選了語言＝翻譯優先，即使有選取
        XCTAssertEqual(KeyboardMode.decide(selectedText: "hello", translateTarget: ja), .translate(target: ja))
    }

    func testOnlyDictateInsertsPartials() {
        let ja = TranslationTarget.all.first { $0.code == "ja" }!
        XCTAssertTrue(KeyboardMode.dictate.insertsPartials)
        XCTAssertFalse(KeyboardMode.edit(selection: "x").insertsPartials)
        XCTAssertFalse(KeyboardMode.translate(target: ja).insertsPartials)
    }

    func testQuickPickDefaultsHaveEnglishInTheMiddle() {
        XCTAssertEqual(QuickPickStore.resolve(nil), ["ja", "ko", "en", "zh-Hant", "fr"])
        XCTAssertEqual(QuickPickStore.resolve(nil)[2], "en")
    }

    func testQuickPickResolveCleansUnknownDuplicatesAndCaps() {
        XCTAssertEqual(QuickPickStore.resolve(["de", "xx", "de", "es"]), ["de", "es"], "不認得的、重複的丟掉")
        XCTAssertEqual(QuickPickStore.resolve(["en", "ja", "ko", "fr", "de", "es", "it"]).count, 5, "最多 5 個")
        XCTAssertEqual(QuickPickStore.resolve([]), QuickPickStore.defaultCodes, "空的回預設，鍵盤長按不能沒語言")
    }

    func testQuickPickToggle() {
        XCTAssertEqual(QuickPickStore.toggled("de", in: ["en"]), ["en", "de"], "加到最後")
        XCTAssertEqual(QuickPickStore.toggled("en", in: ["en", "de"]), ["de"], "已選就移除")
        XCTAssertEqual(QuickPickStore.toggled("en", in: ["en"]), ["en"], "最後一個不能移除")
        XCTAssertEqual(QuickPickStore.toggled("it", in: ["en", "ja", "ko", "fr", "de"]), ["en", "ja", "ko", "fr", "de"], "滿 5 個不加")
    }

    func testQuickPickPersistsThroughDefaults() {
        let suite = UserDefaults(suiteName: "test.quickpick.\(UUID().uuidString)")!
        QuickPickStore.setCodes(["vi", "th", "id"], in: suite)
        XCTAssertEqual(QuickPickStore.targets(in: suite).map(\.zh), ["越南文", "泰文", "印尼文"])
    }

    func testReturnKeyLabels() {
        XCTAssertEqual(ReturnKeyLabel.text(for: .send), "送出")
        XCTAssertEqual(ReturnKeyLabel.text(for: .search), "搜尋")
        XCTAssertEqual(ReturnKeyLabel.text(for: .done), "完成")
        XCTAssertEqual(ReturnKeyLabel.text(for: .default), "換行")
        XCTAssertEqual(ReturnKeyLabel.text(for: nil), "換行")
    }

    func testToneChatDropsSingleTrailingPeriod() {
        XCTAssertEqual(ToneHint.infer(returnKeyType: .send), .chat)
        XCTAssertEqual(ToneHint.infer(returnKeyType: .default), .document)
        XCTAssertEqual(ToneHint.apply("我十分鐘到。", tone: .chat), "我十分鐘到")
        XCTAssertEqual(ToneHint.apply("我十分鐘到。", tone: .document), "我十分鐘到。")
        // 多句不動、太長不動、沒句號不動
        XCTAssertEqual(ToneHint.apply("先開會。再吃飯。", tone: .chat), "先開會。再吃飯。")
        let long = String(repeating: "很", count: 41) + "。"
        XCTAssertEqual(ToneHint.apply(long, tone: .chat), long)
        XCTAssertEqual(ToneHint.apply("好", tone: .chat), "好")
    }

    func testPipelineAppliesTaiwanPhrasesBeforeDictionary() {
        // 字典後套：使用者若把「軟體」再改成「Software」，字典要贏
        // 字典規則：右側緊接文字時視為更長詞的一部分而不換，所以用句尾／標點前的位置測
        let pipeline = TextPipeline(dictionary: ["軟體": "Software"])
        XCTAssertEqual(pipeline.clean("我在用軟件，很好用").output, "我在用Software，很好用")
        XCTAssertEqual(TextPipeline().clean("我在用軟件，很好用").output, "我在用軟體，很好用")
        XCTAssertTrue(pipeline.clean("軟件").steps.first == "taiwan-phrases")
    }

    func testWordCountMixesCJKAndLatin() {
        XCTAssertEqual(UsageInsights.wordCount("今天下午三點開會"), 8)
        XCTAssertEqual(UsageInsights.wordCount("meet at 3 pm today"), 5)
        XCTAssertEqual(UsageInsights.wordCount("我用 UTUVO Type 打字，很快。"), 8)
        XCTAssertEqual(UsageInsights.wordCount(""), 0)
    }

    func testInsightsWeekWindowAndSavings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = DictationRecord(date: now.addingTimeInterval(-10 * 86_400), raw: "", cleaned: "十個字十個字十個字十")
        let recent = DictationRecord(date: now.addingTimeInterval(-86_400), raw: "", cleaned: "五個字五個")
        let insights = UsageInsights.compute(records: [old, recent], now: now)
        XCTAssertEqual(insights.totalWords, 15)
        XCTAssertEqual(insights.weekWords, 5)
        XCTAssertEqual(insights.sessions, 2)
        // 15 字 × (1/36 − 1/150) 分鐘 ≈ 0.317
        XCTAssertEqual(insights.minutesSaved, 15.0 * (1.0 / 36.0 - 1.0 / 150.0), accuracy: 0.0001)
    }
}
