import XCTest
@testable import UTUVOTypeiOS

/// 同音校正的守門（模型的輸出怎麼亂，這裡都只准換同音字）。
final class HomophoneCorrectorTests: XCTestCase {
    func testHarvestTakesOnlyHomophoneSubstitutions() {
        XCTAssertEqual(HomophoneCorrector.harvest(original: "悠悠卡自動除值了", candidate: "悠悠卡自動儲值了"), "悠悠卡自動儲值了")
        XCTAssertEqual(HomophoneCorrector.harvest(original: "我上次做車之前", candidate: "我上次坐車之前"), "我上次坐車之前")
    }

    func testHarvestIgnoresRewritesDeletionsAndNonHomophones() {
        // 模型刪了半句＋改了一個同音字：只收同音字那一個
        XCTAssertEqual(HomophoneCorrector.harvest(original: "而且你看我上次做完，應該說我上次坐車之前就除值了",
                                                   candidate: "而且你看我上次坐車之前就儲值了"),
                       "而且你看我上次做完，應該說我上次坐車之前就儲值了")
        XCTAssertEqual(HomophoneCorrector.harvest(original: "他在錄音室", candidate: "她在錄音間"), "他在錄音室", "錄音室→錄音間 不同音；他→她 是猜性別，不換")
    }

    func testListFixesNeedSameLengthHomophones() {
        let text = "他不是及時的，我們在討論看看"
        XCTAssertEqual(HomophoneCorrector.apply(fixes: [("及時", "即時"), ("在討論", "再討論")], to: text), "他不是即時的，我們再討論看看")
        XCTAssertEqual(HomophoneCorrector.apply(fixes: [("及時", "準時")], to: text), text, "不同音不換")
        XCTAssertEqual(HomophoneCorrector.apply(fixes: [("不存在", "不存再")], to: text), text, "原文沒有的不換")
    }

    // 先出字、背景校正回來再換：游標前面還是剛貼的那段才換。
    func testCorrectionSwapOnlyWhenTextStillThere() {
        XCTAssertTrue(CorrectionSwap.canReplace(inserted: "悠悠卡自動除值了", contextBefore: "你看，悠悠卡自動除值了"))
        XCTAssertFalse(CorrectionSwap.canReplace(inserted: "悠悠卡自動除值了", contextBefore: "悠悠卡自動除值了，我"), "使用者已經接著打字")
        XCTAssertFalse(CorrectionSwap.canReplace(inserted: "悠悠卡自動除值了", contextBefore: ""), "游標移走／讀不到")
        XCTAssertTrue(CorrectionSwap.canReplace(inserted: String(repeating: "很長的一段話", count: 40), contextBefore: String(repeating: "很長的一段話", count: 10)), "只給最後一截也算")
        XCTAssertFalse(CorrectionSwap.canReplace(inserted: "悠悠卡自動除值了", contextBefore: "值了"), "太短的一截不夠確定")
    }
}

/// 連講好幾段：前一段的更正晚回來，後面各段一起接回去（2026-09-20 實機：前一段更正被丟掉）。
final class CorrectionChainTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testEarlierSegmentCorrectedAfterLaterSegmentsInserted() {
        let entries = [CorrectionChain.Entry(id: a, inserted: "Jamin 很好用。"), CorrectionChain.Entry(id: b, inserted: "Cloud coad。")]
        let p = CorrectionChain.plan(entries: entries, id: a, corrected: "Gemini 很好用。", contextBefore: "測試：Jamin 很好用。Cloud coad。")
        XCTAssertEqual(p?.previous, "Jamin 很好用。Cloud coad。")
        XCTAssertEqual(p?.current, "Gemini 很好用。Cloud coad。")
        XCTAssertEqual(p?.index, 0)
    }

    func testLastSegmentOnly() {
        let entries = [CorrectionChain.Entry(id: a, inserted: "第一段。", done: true), CorrectionChain.Entry(id: b, inserted: "Cloud coad。")]
        let p = CorrectionChain.plan(entries: entries, id: b, corrected: "Claude Code。", contextBefore: "第一段。Cloud coad。")
        XCTAssertEqual(p?.previous, "Cloud coad。")
        XCTAssertEqual(p?.current, "Claude Code。")
    }

    func testNoSwapWhenUserTypedAfter() {
        let entries = [CorrectionChain.Entry(id: a, inserted: "Jamin 很好用。")]
        XCTAssertNil(CorrectionChain.plan(entries: entries, id: a, corrected: "Gemini 很好用。", contextBefore: "Jamin 很好用。對吧"))
    }

    func testDoneOrUnknownSegmentIgnored() {
        let entries = [CorrectionChain.Entry(id: a, inserted: "Jamin。", done: true)]
        XCTAssertNil(CorrectionChain.plan(entries: entries, id: a, corrected: "Gemini。", contextBefore: "Jamin。"))
        XCTAssertNil(CorrectionChain.plan(entries: entries, id: c, corrected: "Gemini。", contextBefore: "Jamin。"))
    }
}
