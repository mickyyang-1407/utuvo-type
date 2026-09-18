import XCTest
@testable import UTUVOTypeiOS

/// 停頓補標點＋AI 補標點的把關。
final class PunctuationTests: XCTestCase {
    private func tok(_ t: String, _ s: Double, _ d: Double = 0.2) -> TimedToken { TimedToken(text: t, start: s, duration: d) }

    func testCommaOnShortPausePeriodOnLongPause() {
        let tokens = [tok("明天", 0.0), tok("下午", 0.25), tok("三點", 0.5),      // 連續
                      tok("記得", 1.05),                                        // 停 0.35 → 逗號
                      tok("帶", 1.3), tok("檔案", 1.55),
                      tok("然後", 2.75)]                                        // 停 1.0 → 句號
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "明天下午三點，記得帶檔案。然後")
    }

    func testNoDoublePunctuationWhenRecognizerAlreadyAddedOne() {
        let tokens = [tok("好，", 0.0), tok("那就", 1.5)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "好，那就")
    }

    func testQuestionParticleGetsQuestionMark() {
        let tokens = [tok("你", 0), tok("明天", 0.25), tok("有空", 0.5), tok("嗎", 0.75), tok("我", 2.0)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "你明天有空嗎？我")
    }

    func testLatinSpacingAndPunctuation() {
        let tokens = [tok("send", 0), tok("the", 0.25), tok("stems", 0.5), tok("by", 1.1), tok("Friday", 1.35), tok("thanks", 2.6)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "send the stems, by Friday. thanks")
    }

    func testMixedCJKLatinHasNoSpaceInserted() {
        let tokens = [tok("錄音室", 0), tok("Atmos", 0.25), tok("母帶", 0.5)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "錄音室Atmos母帶", "中英相鄰不插空白（沿用辨識器原樣）")
    }

    /// 2026-09-18 實機的真實片段時間：首尾相連、看不到停頓；靜音段由音訊能量量出。
    /// 辨識器原文：「…錄音室把昨天…一次會你明天…的話我們三點見。」
    func testDeviceSegmentsWithMeasuredSilences() {
        let segs: [(String, Double, Double)] = [
            ("我",0.00,0.18),("今天",0.18,0.45),("早上",0.63,0.45),("去",1.08,0.24),("錄音室",1.32,0.81),("把",2.25,0.30),
            ("昨天",2.55,0.39),("那首歌",2.94,0.63),("的母帶",3.57,0.60),("重新",4.17,0.54),("對了",4.71,0.30),("一",5.01,0.21),
            ("次，",5.22,0.48),("結果",5.70,0.45),("發現",6.15,0.51),("低頻",6.66,0.45),("還是",7.11,0.42),("太多，",7.53,0.81),
            ("所以",8.34,0.51),("下午",8.85,0.45),("要",9.30,0.18),("再開",9.48,0.48),("一",9.96,0.18),("次",10.14,0.21),
            ("會",10.35,0.39),("你",10.83,0.27),("明天",11.10,0.45),("有空",11.55,0.48),("嗎？",12.03,0.33),("如果",12.36,0.45),
            ("可以",12.81,0.39),("的話",13.20,0.60),("我們",13.80,0.42),("三",14.22,0.27),("點見。",14.49,0.87),
        ]
        let tokens = segs.map { TimedToken(text: $0.0, start: $0.1, duration: $0.2) }
        XCTAssertEqual(PausePunctuator.punctuate(tokens), tokens.map(\.text).joined(), "只靠片段時間：一個標點都補不出來（實機現象）")
        let silences = [(2.06,0.30),(5.56,0.22),(8.06,0.32),(10.68,0.22),(12.20,0.22),(13.62,0.30)].map { SilenceInterval(start: $0.0, duration: $0.1) }
        XCTAssertEqual(PausePunctuator.punctuate(tokens, silences: silences),
                       "我今天早上去錄音室，把昨天那首歌的母帶重新對了一次，結果發現低頻還是太多，所以下午要再開一次會，你明天有空嗎？如果可以的話，我們三點見。")
    }

    func testSilenceDetectorAdaptiveThreshold() {
        // 背景 −55 dB、講話 −20 dB；中間一段 0.3 s 靜音、一段 0.1 s 短停（不算）。
        var samples: [LevelSample] = []
        var t = 0.0
        func add(_ db: Float, _ seconds: Double) {
            let n = Int(seconds / 0.02)
            for _ in 0..<n { samples.append(LevelSample(time: t, duration: 0.02, db: db)); t += 0.02 }
        }
        add(-55, 0.1); add(-20, 1.0); add(-55, 0.3); add(-20, 1.0); add(-55, 0.1); add(-20, 1.0)
        let found = SilenceDetector.intervals(samples)
        XCTAssertEqual(found.count, 1, "只有中間 0.3 s 那段；0.1 s 的短停不到 0.18 s 門檻")
        XCTAssertEqual(found.first?.start ?? -1, 1.1, accuracy: 0.001)
        XCTAssertEqual(found.first?.duration ?? -1, 0.3, accuracy: 0.001)
    }

    func testEmptyTokens() {
        XCTAssertEqual(PausePunctuator.punctuate([]), "")
    }

    // MARK: 把關

    func testGuardAcceptsPunctuationOnlyChanges() {
        XCTAssertTrue(PunctuationGuard.preservesText(original: "明天下午三點記得帶檔案然後確認規格",
                                                     candidate: "明天下午三點，記得帶檔案。然後確認規格。"))
        XCTAssertTrue(PunctuationGuard.preservesText(original: "send the stems by friday",
                                                     candidate: "Send the stems by Friday."), "大小寫不算改字")
    }

    func testGuardRejectsAnyWordChange() {
        XCTAssertFalse(PunctuationGuard.preservesText(original: "明天下午三點記得帶檔案",
                                                      candidate: "明天下午三點，請記得帶檔案。"), "多了一個「請」")
        XCTAssertFalse(PunctuationGuard.preservesText(original: "錄音室對Atmos母帶",
                                                      candidate: "錄音室Atmos母帶。"), "少了一個「對」")
        XCTAssertFalse(PunctuationGuard.preservesText(original: "明天見", candidate: "明日見。"), "換字")
        XCTAssertFalse(PunctuationGuard.preservesText(original: "", candidate: ""), "空的不算通過")
    }

    func testOnceGateOnlyOneWinner() {
        let gate = OnceGate()
        XCTAssertTrue(gate.claim())
        XCTAssertFalse(gate.claim())
    }

    // MARK: - 2026-09-18 不靠停頓的規則（問句、轉折逗號；繁簡都要）

    func testQuestionsGetQuestionMark() {
        for q in ["你明天有空嗎", "你要吃什麼", "我們約在哪裡", "你可不可以拍一下你的立可帶給我看",
                  "這樣是不是比較好", "那你呢", "明天幾點", "你為什麼不早說", "Can you send it by Friday",
                  "what time is it",
                  // 簡體
                  "你明天有空吗", "你要吃什么", "我们约在哪里", "你为什么不早说", "明天会不会下雨", "你怎么了"] {
            let out = ClauseRules.finish(q)
            XCTAssertTrue(out.hasSuffix("？") || out.hasSuffix("?"), "應該是問句：\(q) → \(out)")
        }
    }

    func testStatementsDoNotGetQuestionMark() {
        for s in ["我不知道他是不是要來", "哈哈，我現在用我自己的輸入方式在打字耶", "我還在做呢", "他多麼", "那麼",
                  "什麼都好", "I will send it tomorrow", "我們要去金玉堂買文具", "這麼",
                  "我不确定他会不会来", "这么", "我们明天见", "我不怎麼喜歡這首"] {
            XCTAssertEqual(ClauseRules.finish(s), s, "不該補問號：\(s)")
        }
    }

    func testQuestionMarkAtPeriodGapUsesClauseRules() {
        let tokens = [TimedToken(text: "你要吃什麼", start: 0, duration: 1), TimedToken(text: "我請客", start: 1.8, duration: 0.8)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "你要吃什麼？我請客")
    }

    func testConnectorCommas() {
        XCTAssertEqual(ClauseRules.connectorCommas("我今天本來想去錄音室但是下雨了"), "我今天本來想去錄音室，但是下雨了")
        XCTAssertEqual(ClauseRules.connectorCommas("客戶還沒回信所以我們先等"), "客戶還沒回信，所以我們先等")
        XCTAssertEqual(ClauseRules.connectorCommas("客户还没回信然后我们先等"), "客户还没回信，然后我们先等")
    }

    func testConnectorCommasLeaveGluedAndShortAlone() {
        for s in ["所以我們先等", "就是因為下雨才沒去", "這次混音的結果很好", "他不只是老師", "好，但是不行", "我想但是",
                  "就是因为下雨才没去", "这次混音的结果很好"] {
            XCTAssertEqual(ClauseRules.connectorCommas(s), s, "不該補逗號：\(s)")
        }
    }
}
