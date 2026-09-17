import XCTest
@testable import UTUVOTypeCore

final class TaiwanPhrasesTests: XCTestCase {
    func testConvertsCommonITTerms() {
        XCTAssertEqual(TaiwanPhrases.apply("把軟件的數據庫設置改成默認"), "把軟體的資料庫設定改成預設")
        XCTAssertEqual(TaiwanPhrases.apply("鼠標點視頻裡的鏈接"), "滑鼠點影片裡的連結")
    }

    func testLongestMatchWins() {
        // 「數據庫」要整個變「資料庫」，不能先被「數據」吃成「資料庫」以外的怪字
        XCTAssertEqual(TaiwanPhrases.apply("數據庫和數據"), "資料庫和資料")
        XCTAssertEqual(TaiwanPhrases.apply("源代碼裡的代碼"), "原始碼裡的程式碼")
    }

    func testIdempotentAndLeavesTaiwanTextAlone() {
        let taiwan = "軟體、資料庫、滑鼠、螢幕都是台灣說法"
        XCTAssertEqual(TaiwanPhrases.apply(taiwan), taiwan)
        let once = TaiwanPhrases.apply("軟件和硬件")
        XCTAssertEqual(TaiwanPhrases.apply(once), once)
    }

    func testTableHasNoReverseEntries() {
        // 冪等的前提：沒有任何 value 又是別條的 key
        let keys = Set(TaiwanPhrases.table.keys)
        for value in TaiwanPhrases.table.values {
            XCTAssertFalse(keys.contains(value), "reverse entry: \(value)")
        }
    }

    func testEmptyAndLatin() {
        XCTAssertEqual(TaiwanPhrases.apply(""), "")
        XCTAssertEqual(TaiwanPhrases.apply("ship it today"), "ship it today")
    }
}
