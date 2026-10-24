import XCTest
@testable import UTUVOTypeCore

final class DictationPolishTests: XCTestCase {
    func testDictionaryCorrectionsAreProviderIndependent() {
        XCTAssertTrue(DictationPolish.accepts(
            original: "這次的 Dolbe Edmos 混音是在 Protuos 上面做的。",
            cleaned: "這次的 Dolby Atmos 混音是在 Pro Tools 上面做的。",
            terms: ["Dolby Atmos", "Pro Tools"]))
        XCTAssertFalse(DictationPolish.accepts(original: "請把資料寄給業務部門", cleaned: "請不要把資料寄給業務部門"))
        XCTAssertFalse(DictationPolish.accepts(original: "請不要把資料寄給業務部門", cleaned: "請把資料寄給業務部門"))
    }

    func testUnpunctuatedSelfCorrectionKeepsFinalValue() {
        XCTAssertTrue(DictationPolish.accepts(original: "我昨天是要四點不對不對三點出發", cleaned: "我昨天是要三點出發"))
        XCTAssertTrue(DictationPolish.accepts(original: "取樣率用 48K不對是 96K。", cleaned: "取樣率用 96K。"))
        XCTAssertTrue(DictationPolish.accepts(original: "金額是 1200，不對是 12,000塊。", cleaned: "金額是 12000 塊。"))
        XCTAssertFalse(DictationPolish.accepts(original: "金額是 1200，不對是 12,000塊。", cleaned: "金額是 1200 塊。"))
    }

    func testAmountsNegationAndAnswersCannotSlipThroughOverlap() {
        XCTAssertFalse(DictationPolish.accepts(original: "we cannot send the package", cleaned: "we cannon send the package", terms: ["cannon"]))
        XCTAssertFalse(DictationPolish.accepts(original: "這次專案的報價金額是1200元，請確認後再安排匯款。", cleaned: "這次專案的報價金額是12000元，請確認後再安排匯款。"))
        XCTAssertFalse(DictationPolish.accepts(original: "今天天氣怎麼樣", cleaned: "今天天氣晴朗，氣溫大約25度。"))
        XCTAssertFalse(DictationPolish.accepts(original: "這樣不對，不能寄出", cleaned: "這樣，可以寄出"))
    }

    func testRelevantPersonalTermSurvivesLargeDictionaryAndLocalLimit() {
        var dictionary = Dictionary(uniqueKeysWithValues: (0..<519).map { ("Term\($0)", "") })
        dictionary["Dolby Atmos"] = ""
        let selected = DictationPolish.rankedTerms(text: "這次 Dolbe Edmos 的混音", dictionary: dictionary)
        XCTAssertEqual(selected.first, "Dolby Atmos")
        XCTAssertEqual(selected, DictationPolish.rankedTerms(text: "這次 Dolbe Edmos 的混音", dictionary: dictionary))
    }
}
