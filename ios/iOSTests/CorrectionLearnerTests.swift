import XCTest
@testable import UTUVOTypeiOS

/// 自動學字典：只學「語音貼上後刪掉重打的同音字」。
final class CorrectionLearnerTests: XCTestCase {
    private func run(dictated: String, deleteFromEnd n: Int, type pieces: [String]) -> (wrong: String, right: String)? {
        var l = CorrectionLearner()
        l.dictationInserted(dictated)
        var doc = Array(dictated)
        for _ in 0..<n { l.willDelete(doc.last); doc.removeLast() }
        var learned: (wrong: String, right: String)?
        for p in pieces { if let r = l.didType(p) { learned = r } }
        return learned
    }

    func testLearnsHomophoneFix() {
        let r = run(dictated: "悠悠卡自動除值", deleteFromEnd: 2, type: ["儲值"])
        XCTAssertEqual(r?.wrong, "除值"); XCTAssertEqual(r?.right, "儲值")
    }

    func testLearnsWhenTypedInPieces() {
        let r = run(dictated: "他不是及時", deleteFromEnd: 2, type: ["即", "時"])
        XCTAssertEqual(r?.wrong, "及時"); XCTAssertEqual(r?.right, "即時")
    }

    func testDoesNotLearnChangeOfMind() {
        XCTAssertNil(run(dictated: "我們明天開會", deleteFromEnd: 4, type: ["後天開會"]), "明天→後天 讀音不同＝改主意")
    }

    func testDoesNotLearnSingleCharacter() {
        XCTAssertNil(run(dictated: "我明天在", deleteFromEnd: 1, type: ["再"]), "單字學了會套到全部「在」")
    }

    func testDoesNotLearnDifferentLengthOrRewrite() {
        XCTAssertNil(run(dictated: "悠悠卡自動除值", deleteFromEnd: 2, type: ["儲值了"]))
        XCTAssertNil(run(dictated: "一二三四五六七八九十一二三四", deleteFromEnd: 14, type: ["全部重寫"]))
    }

    func testDoesNotLearnOutsideDictatedText() {
        var l = CorrectionLearner()
        l.dictationInserted("我到了")
        l.willDelete("除"); l.willDelete("自")      // 刪的是游標前別的字（不在剛聽寫的那段）
        XCTAssertNil(l.didType("自儲"))
    }

    func testExpiresAfterWindow() {
        var l = CorrectionLearner()
        let t0 = Date()
        l.dictationInserted("自動除值", at: t0)
        let later = t0.addingTimeInterval(CorrectionLearner.window + 1)
        l.willDelete("值", at: later); l.willDelete("除", at: later)
        XCTAssertNil(l.didType("儲值", at: later))
    }
}
