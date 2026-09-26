import XCTest
@testable import UTUVOTypeCore

/// 2026-09-11：本機 4B editor 對單一敘述也加 "- "，實測「嗯等一下開會」→「- 等一下開會」。
final class OutputShapeTests: XCTestCase {

    func testLoneBulletIsStripped() {
        XCTAssertEqual(OutputShape.stripLoneBullet("- 等一下開會"), "等一下開會")
        XCTAssertEqual(OutputShape.stripLoneBullet("* 等一下開會"), "等一下開會")
        XCTAssertEqual(OutputShape.stripLoneBullet("• 等一下開會"), "等一下開會")
    }

    func testRealMultiItemListIsUntouched() {
        let list = "- 寫報告\n- 回信\n- 開會"
        XCTAssertEqual(OutputShape.stripLoneBullet(list), list, "真的多項條列不准動")
    }

    func testTwoItemListIsUntouched() {
        let list = "- 寫報告\n- 回信"
        XCTAssertEqual(OutputShape.stripLoneBullet(list), list)
    }

    func testPlainSentenceIsUntouched() {
        XCTAssertEqual(OutputShape.stripLoneBullet("等一下開會。"), "等一下開會。")
    }

    func testHyphenInsideSentenceIsNotABullet() {
        XCTAssertEqual(OutputShape.stripLoneBullet("Dolby Atmos - 母帶交付"), "Dolby Atmos - 母帶交付")
    }

    func testDashWithoutSpaceIsNotABullet() {
        XCTAssertEqual(OutputShape.stripLoneBullet("-40 LKFS 是目標值"), "-40 LKFS 是目標值")
    }

    func testLeadingWhitespaceBulletIsStripped() {
        XCTAssertEqual(OutputShape.stripLoneBullet("  - 等一下開會  "), "等一下開會")
    }

    func testEmptyStringSurvives() {
        XCTAssertEqual(OutputShape.stripLoneBullet(""), "")
    }

    func testSingleLineJoinsParagraphs() {
        XCTAssertEqual(OutputShape.singleLine("第一段。\n\n另外第二段。"), "第一段。另外第二段。")
        XCTAssertEqual(OutputShape.singleLine("今天有三件事\n第一買牛奶\n第二回email。"), "今天有三件事第一買牛奶第二回email。")
        XCTAssertEqual(OutputShape.singleLine("Done.\n\nNext we ship."), "Done. Next we ship.")
        XCTAssertEqual(OutputShape.singleLine("Hi,\n\n謝謝"), "Hi,謝謝")
        XCTAssertEqual(OutputShape.singleLine("沒有換行"), "沒有換行")
    }
}
