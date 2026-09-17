import XCTest
@testable import UTUVOTypeCore

/// 釘住產品的隱私宣稱：只讀選取文字與周圍一小段，而且有硬上限。
/// 2026-09-11 之前這兩個數字是 AccessibilitySupport 裡的 magic number、零測試——
/// 有人改大不會有東西變紅。
final class ContextBoundsTests: XCTestCase {

    func testSelectedTextLimitIsTwelveThousand() {
        XCTAssertEqual(ContextBounds.selectedTextLimit, 12_000,
                       "選取文字上限是對外宣稱過的數字，要改先改隱私文件")
    }

    func testSurroundingLimitsAreSmall() {
        XCTAssertEqual(ContextBounds.surroundingRadius, 1_000)
        XCTAssertEqual(ContextBounds.surroundingLimit, 2_000)
        XCTAssertLessThan(ContextBounds.surroundingLimit, ContextBounds.selectedTextLimit,
                          "周圍上下文永遠比選取文字更保守")
    }

    func testLongSelectionIsTruncatedToLimit() {
        let long = String(repeating: "字", count: 20_000)
        let bounded = ContextBounds.boundedSelectedText(long)
        XCTAssertEqual(bounded.count, ContextBounds.selectedTextLimit)
    }

    func testLongSurroundingIsTruncatedToLimit() {
        let long = String(repeating: "字", count: 20_000)
        XCTAssertEqual(ContextBounds.boundedSurroundingText(long).count, ContextBounds.surroundingLimit)
    }

    func testShortTextIsUntouched() {
        XCTAssertEqual(ContextBounds.boundedSelectedText("一小段文字"), "一小段文字")
        XCTAssertEqual(ContextBounds.boundedSurroundingText("一小段文字"), "一小段文字")
    }

    func testTextExactlyAtLimitIsUntouched() {
        let exact = String(repeating: "字", count: ContextBounds.selectedTextLimit)
        XCTAssertEqual(ContextBounds.boundedSelectedText(exact).count, ContextBounds.selectedTextLimit)
    }

    /// 中文一字＝一個 Character：上限不可以被當成 byte 數（否則實際讀到的字數只有三分之一，
    /// 或反過來讀進三倍的量）。
    func testLimitCountsCharactersNotBytes() {
        let text = String(repeating: "字", count: 100)
        XCTAssertEqual(ContextBounds.bounded(text, limit: 50).count, 50)
        XCTAssertEqual(ContextBounds.bounded(text, limit: 50).utf8.count, 150)
    }

    func testZeroLimitReadsNothing() {
        XCTAssertEqual(ContextBounds.bounded("任何東西", limit: 0), "")
    }
}
