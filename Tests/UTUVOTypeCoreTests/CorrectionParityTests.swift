import XCTest
@testable import UTUVOTypeCore

final class CorrectionParityTests: XCTestCase {
    // Keep these input/output pairs byte-for-byte aligned with Kotlin's CorrectionParityTest.
    private let corrections: [(String, String)] = [
        ("我們約3點開會,不對,4點,地點在3樓", "我們約4點開會,地點在3樓"),
        ("取樣率用48K,不對,是96K。", "取樣率用96K。"),
        ("檔名叫做Final V3,啊不對,是Final V4。", "檔名叫做Final V4。"),
        ("金額是12000,不對,是12000塊。", "金額是12000塊。"),
        ("幫我轉寄給小雅跟小博,不是,是小雅跟小潘。", "幫我轉寄給小雅跟小潘。"),
        ("這次上課的教室改成四樓", "這次上課的教室改成四樓"),
        ("請參考第3章,不對,是第4章。", "請參考第4章。"),
        ("版本為final_v3,不對,是final_v4。", "版本為final_v4。"),
        ("會議排在星期三,不對,星期四。", "會議排在星期四。"),
        ("會議排在禮拜三,不對,禮拜四。", "會議排在禮拜四。"),
        ("約星期三，不對，下個星期四", "約下個星期四"),
        ("約3點開會,不對,4點\r\n在3樓", "約4點開會\r\n在3樓"),
        ("我是剛上去，喔不對，剛出門要搭937。", "我是剛出門要搭937。"),
        ("會議原訂3點,不對,就是4點。", "會議原訂4點。"),
        ("明天三點半開會不是三點是四點", "明天三點半開會四點"),
        ("明天不是週一，是週二開會", "明天週二開會"),
        ("今天開會,不對,明天早上開會。", "明天早上開會。"),
        ("我們約3點開會在家,不對,4點在公司。", "我們約3點開會在家,不對,4點在公司。"),
        ("我不是生氣，是累了", "我是累了"),
        ("這不是我的，是他的", "這是他的"),
    ]

    // Ordinary uses and near-matches must survive deterministic correction unchanged.
    private let counterexamples: [(String, String)] = [
        ("我覺得不對", "我覺得不對"),
        ("這不是我的", "這不是我的"),
        ("這不是我的，是不是你的", "這不是我的，是不是你的"),
        ("他去台南玩，不對，南投下雨。", "他去台南玩，不對，南投下雨。"),
        ("是不是要改成四點", "是不是要改成四點"),
        ("應該是明天吧", "應該是明天吧"),
        ("不對稱", "不對稱"),
        ("不是嗎？", "不是嗎？"),
        ("不是星期四而是星期三", "不是星期四而是星期三"),
        ("教室改成四樓", "教室改成四樓"),
        ("我想問是不是要改成四點", "我想問是不是要改成四點"),
        ("我覺得這件事不對勁", "我覺得這件事不對勁"),
        ("這不是我說的", "這不是我說的"),
        ("是不是應該是明天", "是不是應該是明天"),
        ("應該是可以", "應該是可以"),
        ("他說的不是嗎？", "他說的不是嗎？"),
        ("這個不對稱設計很有趣", "這個不對稱設計很有趣"),
        ("我不是說你錯", "我不是說你錯"),
        ("剛才那樣不對勁", "剛才那樣不對勁"),
        ("你是不是要改成四點", "你是不是要改成四點"),
        ("明天應該是星期三", "明天應該是星期三"),
        ("不是這樣嗎", "不是這樣嗎"),
        ("改成中文版本", "改成中文版本"),
    ]

    func testCorrectionCases() {
        for (input, expected) in corrections {
            XCTAssertEqual(Normalizer.applySelfCorrection(input), expected, input)
        }
    }

    func testNormalizerPreservesNotIsCorrectionThroughRepeatStage() {
        let input = "幫我轉寄給小雅跟小博,不是,是小雅跟小潘。"
        XCTAssertEqual(
            Normalizer().normalize(input).cleaned,
            "幫我轉寄給小雅跟小潘。",
            "Repeat collapse must not eat the copula in 不是,是"
        )
    }

    func testOrdinaryPhrasesRemainUntouched() {
        for (input, expected) in counterexamples {
            XCTAssertEqual(Normalizer.applySelfCorrection(input), expected, input)
        }
    }
}
