import XCTest
@testable import UTUVOTypeCore

/// 長文分段＋條列逐句判斷（2026-09-19）。口語長文樣本模擬辨識器輸出（已有標點）。
final class ParagraphTests: XCTestCase {
    let n = Normalizer()

    static let meeting = "嗯今天下午跟唱片公司開會，主要是討論下一張專輯的混音時程，他們希望十月底之前可以交出第一版的 Atmos 混音，然後我跟他們說這個時間有點趕，因為我們還在等錄音室那邊把弦樂的分軌整理好。然後關於預算的部分，他們說可以再加百分之十，但是要把 stereo 版本也一起交。另外他們也問到之後有沒有可能做現場演唱會的空間音訊版本，我說可以先評估看看，需要先看場地的錄音條件。最後我們約好下禮拜三再開一次會，確認最後的時程。"
    static let email = "老師你好，我是上週來上課的同學，想請問一下期末作業的部分。首先是作業的長度，老師上課說大概三到五分鐘，但是如果我的作品是七分鐘會不會扣分？再來是交件格式，我們需要交 ADM BWF 還是只要交 binaural 的立體聲版本就可以了？還有就是如果我要用自己錄的素材，需要附上錄音的 session 檔案嗎？謝謝老師，不好意思問了這麼多問題。"
    static let review = "我覺得這次的改版方向是對的，整體的介面比之前乾淨很多，特別是主畫面的光球放大之後，一眼就知道要按哪裡。不過鍵盤的部分我還是覺得有點擠，左右兩排的按鈕距離光球太近了，手指大一點的人可能會按錯。然後翻譯的功能我試了幾次，英文跟日文都還不錯，但是韓文偶爾會把人名翻錯。對了，還有一個小問題，就是在夜間模式的時候，字幕帶的文字顏色有點太淡了，看不太清楚。整體來說我給這個版本八十分，再修一下應該就可以上架了。"

    func paragraphs(_ s: String) -> [String] { n.normalize(s).cleaned.components(separatedBy: "\n\n") }

    func testMeetingRecapSplitsAtTopicShifts() {
        let p = paragraphs(Self.meeting)
        XCTAssertEqual(p.count, 4, "\(p)")
        XCTAssertTrue(p[1].hasPrefix("關於預算"), "句首「然後」接轉折詞要拿掉：\(p[1])")
        XCTAssertTrue(p[2].hasPrefix("另外"))
        XCTAssertEqual(p[3], "最後我們約好下禮拜三再開一次會，確認最後的時程。", "「最後的時程」不能被當條列切開")
        XCTAssertFalse(n.normalize(Self.meeting).cleaned.contains("，\n"), "不能切在句子中間")
    }

    func testEmailGetsGreetingLineAndClosing() {
        let p = paragraphs(Self.email)
        XCTAssertEqual(p.first, "老師你好，")
        XCTAssertEqual(p.last, "謝謝老師，不好意思問了這麼多問題。")
        XCTAssertTrue(p.contains { $0.hasPrefix("首先") } && p.contains { $0.hasPrefix("再來") } && p.contains { $0.hasPrefix("還有") })
    }

    func testReviewSplitsAtWeakTurnAndSummary() {
        let p = paragraphs(Self.review)
        XCTAssertEqual(p.count, 4, "\(p)")
        XCTAssertTrue(p[1].hasPrefix("不過"))
        XCTAssertTrue(p[3].hasPrefix("整體來說"))
    }

    func testEveryParagraphEndsOnASentenceBoundary() {
        for s in [Self.meeting, Self.email, Self.review] {
            for p in paragraphs(s) {
                XCTAssertTrue(["。", "？", "！", "，"].contains(String(p.last!)), "段落要收在句界：\(p)")
            }
        }
    }

    // 不該動的

    func testShortTextUntouched() {
        let s = "今天開會。另外記得買咖啡。最後回信。"
        XCTAssertFalse(n.normalize(s).cleaned.contains("\n\n"))
    }

    func testUnpunctuatedLongTextUntouched() {
        let s = String(repeating: "我今天一整天都在處理混音案子另外還要回信給客戶", count: 5)
        XCTAssertFalse(n.normalize(s).cleaned.contains("\n\n"), "沒有句界就不分段")
    }

    func testExistingLineBreaksUntouched() {
        XCTAssertEqual(Normalizer.paragraphize("第一行。\n" + Self.review), "第一行。\n" + Self.review)
    }

    func testDecimalAndVersionAreNotSentenceEnds() {
        XCTAssertEqual(Normalizer.splitSentences("版本 v0.2.1 跟 3.5 秒. Next one").count, 2)
    }

    // 條列：逐句、不同 cue 才算

    func testNarrativeThenThenIsNotAList() {
        let s = "我先去錄音室，然後跟工程師討論，然後再回家。"
        XCTAssertFalse(n.normalize(s).cleaned.contains("\n"), "同一個 cue 講兩次是敘事不是條列")
    }

    func testFirstEditionIsNotAList() {
        XCTAssertFalse(n.normalize("他們想要第一版的混音，最後的時程再確認。").cleaned.contains("\n"))
    }

    func testCompactListsStillBreak() {
        XCTAssertEqual(n.normalize("今天有三件事第一買牛奶第二回email第三寫報告。").cleaned, "今天有三件事\n第一買牛奶\n第二回email\n第三寫報告。")
        XCTAssertEqual(n.normalize("首先整理桌面其次回信最後趕稿。").cleaned, "首先整理桌面\n其次回信\n最後趕稿。")
        XCTAssertEqual(n.normalize("接下來是測試然後是驗收最後是上線。").cleaned, "接下來是測試\n然後是驗收\n最後是上線。")
    }
}
