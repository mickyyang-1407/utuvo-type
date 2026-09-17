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

    func testQuickPickHasEnglishInTheMiddle() {
        XCTAssertEqual(TranslationTarget.quickPick.count, 5)
        XCTAssertEqual(TranslationTarget.quickPick[2].code, "en")
    }

    func testReturnKeyLabels() {
        XCTAssertEqual(ReturnKeyLabel.text(for: .send), "送出")
        XCTAssertEqual(ReturnKeyLabel.text(for: .search), "搜尋")
        XCTAssertEqual(ReturnKeyLabel.text(for: .done), "完成")
        XCTAssertEqual(ReturnKeyLabel.text(for: .default), "換行")
        XCTAssertEqual(ReturnKeyLabel.text(for: nil), "換行")
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
