import XCTest
@testable import UTUVOTypeCore

/// 插入後追蹤使用者修改（2026-10-13 對齊 Typeless）。
final class EditTrackerTests: XCTestCase {
    private func pairs(_ a: String, _ b: String) -> [String] {
        EditTracker.corrections(inserted: a, current: b).map { "\($0.from)→\($0.to)" }
    }

    func testChineseHomophoneFixesBecomeTwoCharacterWords() {
        XCTAssertEqual(pairs("我搭到元山站以後再換車，悠悠卡記得先除值",
                             "我搭到圓山站以後再換車，悠遊卡記得先儲值"),
                       ["元山→圓山", "悠卡→遊卡", "除值→儲值"])
    }

    func testEnglishFixExpandsToWholeWord() {
        XCTAssertEqual(pairs("跟 Pro Tool 的 session 備份", "跟 Pro Tools 的 session 備份"), [],
                       "純補字（加 s）不是錯字替換，不學")
        XCTAssertEqual(pairs("確認 Atmus 的交付規格", "確認 Atmos 的交付規格"), ["Atmus→Atmos"])
    }

    func testLargeRewriteIsNotTracked() {
        XCTAssertEqual(pairs("明天下午三點在公司見", "改成後天早上十點線上開會好了"), [])
    }

    func testPureDeletionAndUnchangedAreNotTracked() {
        XCTAssertEqual(pairs("嗯我們明天見", "我們明天見"), [])
        XCTAssertEqual(pairs("一模一樣", "一模一樣"), [])
        XCTAssertEqual(pairs("", "x"), [])
    }

    func testPunctuationOnlyChangesIgnored() {
        XCTAssertEqual(pairs("好的，明天見。", "好的！明天見？"), [])
    }

    // MARK: - delivery-learning-v1：一組替換只算一次、短訊息分母至少 24 字

    func testShortMessagesLearnProperNounFix() {
        XCTAssertEqual(pairs("Utuvo Type 很好", "UTUVO Type 很好"), ["Utuvo→UTUVO"])
        XCTAssertEqual(pairs("我在用 Utuvo 打字", "我在用 UTUVO 打字"), ["Utuvo→UTUVO"])
        XCTAssertEqual(pairs("幫我約 Damie 下午三點", "幫我約 DAMI 下午三點"), ["Damie→DAMI"])
    }

    func testBenchSentenceWithTwoFixesOfTheSameName() {
        // bench pn05：Type r8 輸出，使用者把兩個 Utuvo 都改成 UTUVO。
        let found = pairs("那個 app 在 Mac 上叫做 Utuvo Type，在手機上面叫做 Utuvo Type，被搞混了",
                          "那個 app 在 Mac 上叫做 UTUVO Type，在手機上面叫做 UTUVO Type，被搞混了")
        XCTAssertTrue(found.contains("Utuvo→UTUVO"), "\(found)")
    }

    func testReplacementCountsOnceButLocateCountIsUnchanged() {
        XCTAssertEqual(EditTracker.replacementChangedCount(inserted: "Utuvo", current: "UTUVO"), 4,
                       "刪 tuvo＋加 TUVO 是同一組替換，算 4 個字")
        XCTAssertEqual(EditTracker.changedCount("Utuvo", "UTUVO"), 8,
                       "EditWatcher.locate 用的 changedCount 不變")
    }

    // MARK: - delivery-learning-v2：英文以整個詞為單位、只差大小寫的不自動加

    func testMultiWordLatinFixIsWholeTokens() {
        XCTAssertEqual(pairs("送到 Dummy Music 的教室", "送到 DAMI music 的教室"), ["Dummy Music→DAMI music"])
        XCTAssertEqual(pairs("我用派森寫程式", "我用Python寫程式"), ["派森→Python"])
    }

    func testMoreThanThreeChangedTokensIsARewrite() {
        XCTAssertEqual(pairs("我說 Tom ate red jam 了，大家都笑了", "我說 Tim ata rod jim 了，大家都笑了"), [])
    }

    func testCaseOnlyPairsAreSuggestionsOnly() {
        let tool = EditTracker.corrections(inserted: "設定在 tool 選單裡", current: "設定在 Tool 選單裡")
        XCTAssertEqual(tool, [.init(from: "tool", to: "Tool")])
        XCTAssertEqual(tool.first?.caseOnly, true)
        XCTAssertEqual(tool.first?.isAutoAddEligible, false, "字首大寫的只差大小寫：字典全域替換會誤傷，只留建議")

        let session = EditTracker.Correction(from: "Session", to: "session")
        XCTAssertTrue(session.caseOnly)
        XCTAssertFalse(session.isAutoAddEligible, "改成全小寫的不自動加")

        let brand = EditTracker.Correction(from: "Utuvo", to: "UTUVO")
        XCTAssertTrue(brand.caseOnly)
        XCTAssertTrue(brand.isAutoAddEligible, "改後有兩個以上大寫字母＝品牌寫法，可以自動加")
        XCTAssertTrue(EditTracker.Correction(from: "iphone", to: "iPhone").isAutoAddEligible, "大寫不在字首＝品牌寫法")

        let words = EditTracker.Correction(from: "Dummy Music", to: "DAMI music")
        XCTAssertFalse(words.caseOnly)
        XCTAssertTrue(words.isAutoAddEligible)
        XCTAssertFalse(EditTracker.Correction(from: "Atmus", to: "Atmos").caseOnly)
    }

    func testSpaceToHyphenIsNotLearned() {
        XCTAssertEqual(pairs("在 Mac 上叫 utuvo type 喔", "在 Mac 上叫 utuvo-type 喔"), [], "只改標點／空白不學")
    }

    // MARK: - 2026-10-22 修補（verifier mac-learning2）：學字典用的 key 不借不相干的鄰字

    private func learnable(_ a: String, _ b: String) -> [String] {
        EditTracker.learnableCorrections(inserted: a, current: b).map { "\($0.from)→\($0.to)" }
    }

    func testLearnableSingleCharacterChangesUseTheWholeWord() {
        XCTAssertEqual(learnable("明天跟小美吃飯", "明天跟小梅吃飯"), ["小美→小梅"], "不是「美吃→梅吃」")
        XCTAssertEqual(learnable("我們在元山見面", "我們在圓山見面"), ["元山→圓山"])
        XCTAssertEqual(learnable("好，那我們下次在說", "好，那我們下次再說"), [], "「再」自己一個詞：不學")
        XCTAssertEqual(learnable("他跑的很快", "他跑得很快"), [])
        XCTAssertEqual(learnable("今天的程式馬", "今天的程式碼"), ["程式馬→程式碼"])
        // 兩個字以上的修改、英文修正跟 corrections 一樣
        XCTAssertEqual(learnable("我們要練係客戶", "我們要聯繫客戶"), ["練係→聯繫"])
        XCTAssertEqual(learnable("確認 Atmus 的交付規格", "確認 Atmos 的交付規格"), ["Atmus→Atmos"])
        XCTAssertEqual(learnable("送到 Dummy Music 的教室", "送到 DAMI music 的教室"), ["Dummy Music→DAMI music"])
        XCTAssertEqual(pairs("明天跟小美吃飯", "明天跟小梅吃飯"), ["美吃→梅吃"], "corrections（建議清單相容）行為不變")
    }

    func testCompositionSnapshotsAreDetected() {
        XCTAssertTrue(EditTracker.looksLikeComposition(inserted: "我們在元山見面", current: "我們在yuan山見面"))
        XCTAssertTrue(EditTracker.looksLikeComposition(inserted: "我們在元山見面", current: "我們在yuan shan見面"))
        XCTAssertTrue(EditTracker.looksLikeComposition(inserted: "我們在元山見面", current: "我們在ㄩㄢˊ山見面"))
        XCTAssertFalse(EditTracker.looksLikeComposition(inserted: "我在用 Utuvo 打字", current: "我在用 UTUVO 打字"))
        XCTAssertFalse(EditTracker.looksLikeComposition(inserted: "我們在元山見面", current: "我們在圓山見面"))
        XCTAssertFalse(EditTracker.looksLikeComposition(inserted: "我用派森寫程式", current: "我用Python寫程式"), "有大寫＝打好的英文")
    }
}
