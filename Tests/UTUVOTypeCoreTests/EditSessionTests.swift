import XCTest
@testable import UTUVOTypeCore

/// delivery-learning-3：貼上後的修改追蹤在送出、清空、換焦點、閒置時結算（對齊 Typeless 的四種時機）。
final class EditSessionTests: XCTestCase {
    private let inserted = "Utuvo Type 很好"
    private let edited = "UTUVO Type 很好"

    private func learned(_ outcome: EditSession.Outcome?) -> [String] {
        guard case let .evaluate(original, current)? = outcome else { return [] }
        return EditTracker.corrections(inserted: original, current: current).map { "\($0.from)→\($0.to)" }
    }

    func testReturnEvaluatesTheLastSnapshotEvenAfterTheFieldEmpties() {
        var s = EditSession(inserted: inserted, at: 0)
        s.keyDown(isReturn: false, at: 0.5)
        XCTAssertNil(s.snapshot(edited, at: 0.7))
        let outcome = s.keyDown(isReturn: true, at: 1.0)
        XCTAssertEqual(outcome, .evaluate(original: inserted, edited: edited))
        XCTAssertNil(s.snapshot("", at: 1.2), "結算過一次就不再結算")
        XCTAssertEqual(s.outcome, .evaluate(original: inserted, edited: edited))
        XCTAssertEqual(learned(outcome), ["Utuvo→UTUVO"], "聊天訊息改完名字按 Enter，學得到")
    }

    func testFieldClearedWithoutReturnUsesThePreviousSnapshot() {
        // 按「傳送」按鈕（滑鼠）送出：沒有 Return，欄位直接變空。
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited, at: 2)
        XCTAssertEqual(s.snapshot("", at: 3), .evaluate(original: inserted, edited: edited))
    }

    func testInsertedTextGoneFromNonEmptyFieldCountsAsCleared() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited, at: 2)
        XCTAssertEqual(s.snapshot("下一則完全不同的訊息內容在這裡", at: 3), .evaluate(original: inserted, edited: edited))
    }

    func testFocusChangeEvaluatesWithTheLastSnapshot() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited, at: 2)
        XCTAssertEqual(s.focusChanged(), .evaluate(original: inserted, edited: edited))
    }

    func testIdleForFifteenSecondsEvaluatesOnce() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited, at: 2)
        XCTAssertEqual(s.deadline, 15)
        XCTAssertNil(s.tick(at: 10))
        XCTAssertEqual(s.tick(at: 15), .evaluate(original: inserted, edited: edited))
        XCTAssertNil(s.tick(at: 30), "只結算一次")
    }

    func testKeypressAtFourteenSecondsPushesTheTimeoutToTwentyNine() {
        var s = EditSession(inserted: inserted, at: 0)
        s.keyDown(isReturn: false, at: 14)
        XCTAssertEqual(s.deadline, 29)
        XCTAssertNil(s.tick(at: 15))
        s.snapshot(edited, at: 20)
        XCTAssertNil(s.tick(at: 28.9))
        XCTAssertEqual(s.tick(at: 29), .evaluate(original: inserted, edited: edited))
    }

    func testHardCapIsSixtySeconds() {
        var s = EditSession(inserted: inserted, at: 0)
        for t in stride(from: 10.0, through: 50.0, by: 10) { s.keyDown(isReturn: false, at: t) }
        XCTAssertEqual(s.deadline, 60, "一直有按鍵也最多 60 秒")
        s.snapshot(edited, at: 55)
        XCTAssertNil(s.tick(at: 59.9))
        XCTAssertEqual(s.tick(at: 60), .evaluate(original: inserted, edited: edited))
    }

    func testSecureFieldAbandons() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited, at: 1)
        XCTAssertEqual(s.secureField(), .abandon)
        XCTAssertNil(s.keyDown(isReturn: true, at: 2))
        XCTAssertEqual(s.outcome, .abandon)
    }

    func testUnchangedTextAbandons() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot("前面 " + inserted + " 後面", at: 1)
        XCTAssertEqual(s.keyDown(isReturn: true, at: 2), .abandon)
    }

    func testNoSnapshotAbandons() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(nil, at: 1)   // 讀不到
        XCTAssertEqual(s.keyDown(isReturn: true, at: 2), .abandon)
    }

    /// 打完最後一個字立刻按 Enter（防抖還沒讀到）：快照是改到一半的樣子，寧可不學也不能學到「Utuvo→UTUV」。
    func testKeysAfterTheLastSnapshotMakeItStale() {
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot("UTUV Type 很好", at: 1.0)
        s.keyDown(isReturn: false, at: 1.05)
        XCTAssertEqual(s.keyDown(isReturn: true, at: 1.1), .abandon)

        var cleared = EditSession(inserted: inserted, at: 0)
        cleared.snapshot(edited, at: 1.0)
        cleared.keyDown(isReturn: false, at: 2.0)   // 送出後開始打下一則
        XCTAssertEqual(cleared.snapshot("下一則訊息打到一半", at: 2.2), .abandon)
    }

    func testFullRewriteLearnsNothing() {
        var s = EditSession(inserted: "明天下午三點在公司見", at: 0)
        s.snapshot("改成後天早上十點線上開會好了", at: 1)
        let outcome = s.keyDown(isReturn: true, at: 2)
        XCTAssertEqual(learned(outcome), [], "大改寫不學（EditTracker 的 maxChangedRatio）")
    }

    func testAnchorsEditedFallsBackToTheWholeShortField() {
        // 改的正好是開頭那幾個字：開頭錨點找不到，但欄位裡就只有這一段。
        XCTAssertNil(EditSession.locate(inserted, in: edited))
        var s = EditSession(inserted: inserted, at: 0)
        s.snapshot(edited + " ", at: 1)
        XCTAssertEqual(s.lastSlice, edited)
        XCTAssertNil(EditSession.wholeField("完全不相干的另一段文字", inserted: "我搭到元山站以後再換車"), "不相干的不算")
        XCTAssertNil(EditSession.wholeField(edited + String(repeating: "後面很長的別段文字", count: 3), inserted: inserted),
                     "長度差太多不算")
    }

    func testDocumentFieldStillLocatesTheInsertedSlice() {
        var s = EditSession(inserted: "我搭到元山站以後再換車", at: 0)
        s.snapshot("前面的字。我搭到圓山站以後再換車。後面的字", at: 1)
        let outcome = s.focusChanged()
        XCTAssertEqual(outcome, .evaluate(original: "我搭到元山站以後再換車", edited: "我搭到圓山站以後再換車"))
        XCTAssertEqual(learned(outcome), ["元山→圓山"])
    }

    func testBenchProperNounFixesAreLearnedAfterReturn() {
        // bench pn01／pn05：Type 輸出、使用者改成參考答案後按 Enter。
        var pn01 = EditSession(inserted: "下週六送到 Dummy Music 的教室", at: 0)
        pn01.snapshot("下週六送到 DAMI music 的教室", at: 3)
        XCTAssertEqual(learned(pn01.keyDown(isReturn: true, at: 3.5)), ["Dummy Music→DAMI music"])

        let pn05 = "那個 app 在 Mac 上叫做 Utuvo Type，在手機上面叫做 Utuvo Type，被搞混了"
        var s = EditSession(inserted: pn05, at: 0)
        s.snapshot(pn05.replacingOccurrences(of: "Utuvo", with: "UTUVO"), at: 4)
        XCTAssertTrue(learned(s.keyDown(isReturn: true, at: 5)).contains("Utuvo→UTUVO"))
    }

    // MARK: - 2026-10-22 修補（verifier mac-learning2）：輸入法組字中的快照不學

    /// 拼音輸入法組字時，欄位裡是「我們在yuan山見面」（還沒選字）；使用者用滑鼠選字、按傳送，15 秒後欄位是空的——
    /// 以前拿組字中的快照結算，學到「元→yuan」還自動加成詞彙。整回合放棄。
    func testSnapshotTakenDuringIMECompositionIsNotLearned() {
        var s = EditSession(inserted: "我們在元山見面", at: 0)
        s.snapshot("我們在元山見面", at: 0.4)
        for t in [1.0, 1.1, 1.2, 1.3] { s.keyDown(isReturn: false, at: t) }   // y u a n
        s.snapshot("我們在yuan山見面", at: 1.45)
        XCTAssertEqual(s.snapshot("", at: 16.31), .abandon)

        var zhuyin = EditSession(inserted: "我們在元山見面", at: 0)
        zhuyin.keyDown(isReturn: false, at: 1)
        zhuyin.snapshot("我們在ㄩㄢˊ山見面", at: 1.2)
        XCTAssertEqual(zhuyin.focusChanged(), .abandon, "注音組字也一樣")

        var brand = EditSession(inserted: "我在用 Utuvo 打字", at: 0)
        brand.snapshot("我在用 UTUVO 打字", at: 1)
        XCTAssertEqual(brand.focusChanged(), .evaluate(original: "我在用 Utuvo 打字", edited: "我在用 UTUVO 打字"),
                       "改的是英文、原本就是英文：照常學")
    }
}
