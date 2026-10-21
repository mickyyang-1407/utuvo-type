import XCTest
@testable import UTUVOTypeCore

/// 2026-10-20 Pixel：「但是...辨識」被轉成「但是。..辨識」（第一個點當成句號）。
final class EllipsisPunctuationTests: XCTestCase {
    func testChineseEllipsisBecomesFullWidth() {
        XCTAssertEqual(Normalizer.normalizePunctuation("但是...辨識好像還是笨笨的耶"), "但是……辨識好像還是笨笨的耶")
        XCTAssertEqual(Normalizer.normalizePunctuation("我想想…好了"), "我想想……好了")
        XCTAssertEqual(Normalizer.normalizePunctuation("好.我知道"), "好。我知道")
        XCTAssertEqual(Normalizer.normalizePunctuation("version 1.2.3"), "version 1.2.3")
    }
}
