import XCTest
@testable import UTUVOTypeiOS

/// IOS3：鍵盤增量插入的邊界（v1 的 `text.count > lastText.count` 在辨識器回頭改字時會插錯）。
final class KeyboardEditTests: XCTestCase {

    func testFirstResultInsertsEverything() {
        let plan = IncrementalInsert.plan(previous: "", current: "今天下午三點")
        XCTAssertEqual(plan, .init(deleteCount: 0, insert: "今天下午三點"))
    }

    func testGrowingTranscriptOnlyInsertsTheNewTail() {
        let plan = IncrementalInsert.plan(previous: "今天下午", current: "今天下午三點開會")
        XCTAssertEqual(plan, .init(deleteCount: 0, insert: "三點開會"))
    }

    /// 這條是 v1 的 bug：長度變長但前面被改掉，舊邏輯會插入錯的尾巴。
    func testCorrectionInTheMiddleRewritesFromDivergencePoint() {
        let plan = IncrementalInsert.plan(previous: "今天三點開會", current: "今天四點開會囉")
        XCTAssertEqual(plan, .init(deleteCount: 4, insert: "四點開會囉"))
    }

    /// 這條也是 v1 的 bug：結果變短時舊邏輯整段不更新，文件停在錯字上。
    func testShorterResultDeletesTheExtraTail() {
        let plan = IncrementalInsert.plan(previous: "今天下午三點開會", current: "今天下午三點")
        XCTAssertEqual(plan, .init(deleteCount: 2, insert: ""), "只該刪掉多出來的「開會」兩字")
    }

    func testCompletelyDifferentTextReplacesEverything() {
        let plan = IncrementalInsert.plan(previous: "abc", current: "xyz")
        XCTAssertEqual(plan, .init(deleteCount: 3, insert: "xyz"))
    }

    func testUnchangedTextIsNoop() {
        let plan = IncrementalInsert.plan(previous: "一樣的字", current: "一樣的字")
        XCTAssertTrue(plan.isNoop)
        XCTAssertEqual(plan, .noop)
    }

    func testEmptyCurrentDeletesEverythingWeOwn() {
        let plan = IncrementalInsert.plan(previous: "要刪掉", current: "")
        XCTAssertEqual(plan, .init(deleteCount: 3, insert: ""))
    }

    /// deleteBackward 一次刪一個 Character；emoji 等 grapheme cluster 必須算一個。
    func testGraphemeClustersCountAsOneDelete() {
        let plan = IncrementalInsert.plan(previous: "好👨‍👩‍👧‍👦", current: "好")
        XCTAssertEqual(plan.deleteCount, 1, "一家四口 emoji 是一個 Character")
        XCTAssertEqual(plan.insert, "")
    }

    /// 定稿時把逐字稿換成清理後版本，也是走同一條路。
    func testFinalCleanupReplacesTheDictatedRun() {
        let plan = IncrementalInsert.plan(previous: "嗯我今天很累", current: "我今天很累。")
        XCTAssertEqual(plan.deleteCount, 6)
        XCTAssertEqual(plan.insert, "我今天很累。")
    }
}
