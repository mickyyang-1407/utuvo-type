import XCTest
@testable import UTUVOTypeCore

/// 2026-10-02 Micky：「不要每個句子或最後都用句點，偶爾可以有問號、驚嘆號……一直使用句點會顯得很 AI」。
/// 正例（要改）與反例（不能改）一樣多：錯放問號比多一個句號更難看。
final class SentenceMoodTests: XCTestCase {

    func testQuestionsGetQuestionMarks() {
        let cases = [
            "你明天會來嗎。": "你明天會來嗎？",
            "我想問問你可以嗎。": "我想問問你可以嗎？",
            "這樣好嗎。": "這樣好嗎？",
            "你知道他在哪裡嗎。": "你知道他在哪裡嗎？",
            "我明天會到，你呢。": "我明天會到，你呢？",
            "你明天是不是要上課。": "你明天是不是要上課？",
            "週五有沒有空。": "週五有沒有空？",
            "要不要一起吃飯。": "要不要一起吃飯？",
            "你覺得這個混音怎麼樣。": "你覺得這個混音怎麼樣？",
            "為什麼他還沒回信。": "為什麼他還沒回信？",
            "我們幾點集合。": "我們幾點集合？",
            "這個多少錢。": "這個多少錢？",
            "你明天會來，對吧。": "你明天會來，對吧？",
            "What time is the session.": "What time is the session?",
            "Can you send it tomorrow.": "Can you send it tomorrow?",
        ]
        for (input, expected) in cases { XCTAssertEqual(SentenceMood.apply(input), expected, input) }
    }

    func testStatementsKeepTheirPeriod() {
        let statements = [
            "我不知道他為什麼要這樣。",          // 間接問句
            "一眼就知道要按哪裡。",               // 「知道」＋疑問詞＝陳述（golden 語料抓到的誤判，10-02）
            // review（AGY 10-02）實測誤判成問號的陳述句：
            "我過幾天會寄給妳。", "不管他怎麼說我都不想理他。", "隨便挑哪一個都好。", "無論如何我們都要準時交件。",
            "這件衣服多少有點褪色。", "這是不是事實大家心裡有數。", "我等一下再跟你說怎麼做。", "看你什麼時候方便。",
            "我很清楚他在想什麼。",
            "看得出他有多開心。",
            "我在考慮要不要去。",
            "等一下問他幾點到。",
            "什麼都可以。",                      // 任指
            "誰都知道這件事。",
            "我還在等呢。",                      // 長句的「呢」是語氣
            "明天下午三點開會。",
            "這首歌的混音已經完成了。",
            "我不太記得了。",                    // 「不太……了」不是感嘆
            "We will meet tomorrow.",
            "Is 是英文的 be 動詞。",              // 夾中文：不套英文規則
        ]
        for s in statements { XCTAssertEqual(SentenceMood.apply(s), s, s) }
    }

    func testExclamations() {
        let cases = [
            "太好了。": "太好了！",
            "今天真的太熱了。": "今天真的太熱了！",
            "恭喜你升職。": "恭喜你升職！",
            "謝謝你幫忙。": "謝謝你幫忙！",
            "好漂亮喔。": "好漂亮喔！",
            "哈哈這太好笑了。": "哈哈這太好笑了！",
            "生日快樂。": "生日快樂！",
        ]
        for (input, expected) in cases { XCTAssertEqual(SentenceMood.apply(input), expected, input) }
    }

    /// 多句：只有問句那句變，其他保持；已經是 ？／！ 的不動。
    func testMixedParagraph() {
        XCTAssertEqual(SentenceMood.apply("明天開會改到三點。你可以來嗎。我會帶筆電。"),
                       "明天開會改到三點。你可以來嗎？我會帶筆電。")
        XCTAssertEqual(SentenceMood.apply("真的嗎？太棒了！"), "真的嗎？太棒了！")
    }

    /// 最後一句的句號拿掉；問號驚嘆號留著；分段長文保留。
    func testFinishDropsOnlyTheFinalPeriod() {
        XCTAssertEqual(SentenceMood.finish("明天開會改到三點。你可以來嗎。我會帶筆電。"),
                       "明天開會改到三點。你可以來嗎？我會帶筆電")
        XCTAssertEqual(SentenceMood.finish("你明天會來嗎。"), "你明天會來嗎？")
        XCTAssertEqual(SentenceMood.finish("好。"), "好")
        XCTAssertEqual(SentenceMood.finish("第一段。\n\n第二段結束。"), "第一段。\n\n第二段結束。")
        XCTAssertEqual(SentenceMood.finish("。"), "。")
        XCTAssertEqual(SentenceMood.finish("I will be there."), "I will be there.")   // 英文句點照英文習慣留著
    }

    /// Micky 原話：這段辨識出來每句都是句號——整理後至少最後一句不再有句號。
    func testMickysOwnExample() {
        let raw = "我覺得現在越來越棒，但我一直想修改的是不要每個句子或最後都用句點，偶爾可以有問號、驚歎號等。你還是要稍微了解前後的意思再下判斷，因為一直使用句點會顯得很 AI。就像現在這樣，幾乎都會有句點。"
        let out = SentenceMood.finish(raw)
        XCTAssertFalse(out.hasSuffix("。"), out)
        XCTAssertEqual(out.filter { $0 == "？" }.count, 0, "這段沒有問句，不能亂放問號：\(out)")
    }

    /// 連續兩段聽寫：前一段的句號被拿掉了，緊接著講下一段要把句號補回去；輸入框已清空（訊息送出）就不補。
    func testContinuationPrefix() {
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "我到了", previous: "我到了"), "。")
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "前面的字我到了 ", previous: "我到了"), "。")
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "", previous: "我到了"), "")            // 已送出
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "我到了，", previous: "我到了"), "")      // 使用者自己打了標點
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "你在哪？", previous: "你在哪？"), "")    // 問句本來就有標點
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "I will be there.", previous: "I will be there."), "")
        XCTAssertEqual(SentenceMood.continuationPrefix(before: nil, previous: "我到了"), "")             // 讀不到游標前文字
        XCTAssertEqual(SentenceMood.continuationPrefix(before: "別的內容", previous: "我到了"), "")       // 游標移走了
    }

    /// 管線裡真的有這一步（sentinel）。
    func testNormalizerRunsMoodStage() {
        let n = Normalizer().normalize("你明天會來嗎。")
        XCTAssertTrue(n.appliedSteps.contains("mood"))
        XCTAssertEqual(n.cleaned, "你明天會來嗎？")
    }
}
