import XCTest
@testable import UTUVOTypeiOS

/// 停頓補標點＋AI 補標點的把關。
final class PunctuationTests: XCTestCase {
    private func tok(_ t: String, _ s: Double, _ d: Double = 0.2) -> TimedToken { TimedToken(text: t, start: s, duration: d) }

    /// 2026-09-24 改：停頓只補逗號，長停頓也不補句號（實測回報「一休息就出現句點」）。
    func testPausesOnlyEverProduceCommas() {
        let tokens = [tok("明天", 0.0), tok("下午", 0.25), tok("三點", 0.5),      // 連續
                      tok("記得", 1.05),                                        // 停 0.35 → 逗號
                      tok("帶", 1.3), tok("檔案", 1.55),
                      tok("然後", 2.75)]                                        // 停 1.0 → 也只是逗號
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "明天下午三點，記得帶檔案，然後")
    }

    /// 2026-09-19 實機「我現在在慢慢走過去學校，了」：句尾「了」前面有停頓，不能被切開。
    func testNoPunctuationBeforeSentenceParticle() {
        let tokens = [tok("走過去", 0.0), tok("學校", 0.25),
                      tok("了", 0.85),                                          // 停 0.4 但是語助詞 → 不補
                      tok("你", 1.9), tok("到", 2.15), tok("了", 2.4), tok("嗎", 3.0)]   // 停 0.85 → 逗號；「嗎」前停 0.4 也不補
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "走過去學校了，你到了嗎？")
    }

    /// 新引擎實測：短停頓後的問句子句補問號；中文句子裡英文結尾的逗號用全形。
    func testQuestionAtShortPauseAndFullWidthAfterLatin() {
        let tokens = [tok("會不會", 0.0), tok("扣分", 0.25),
                      tok("我們", 0.85), tok("交", 1.1), tok("ADM", 1.35),        // 停 0.4 → 問號
                      tok("還是", 2.05), tok("WAV", 2.3)]                          // 停 0.5，但「我們交ADM」只有 4 個字＝遲疑
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "會不會扣分？我們交ADM還是WAV")
        let longer = [tok("我們", 0.0), tok("這次", 0.25), tok("要", 0.5), tok("交", 0.7), tok("ADM", 0.9),
                      tok("還是", 1.6), tok("WAV", 1.85)]                           // 一小句夠長 → 全形逗號
        XCTAssertEqual(PausePunctuator.punctuate(longer), "我們這次要交ADM，還是WAV")
    }

    /// 新引擎實測的兩種誤判：轉述的正反問、「了＋幾次」。
    func testReportedAndFewTimesAreNotQuestions() {
        XCTAssertFalse(ClauseRules.isQuestion("另外他們也問到之後有沒有可能做現場的版本"))
        XCTAssertFalse(ClauseRules.isQuestion("然後翻譯的功能我試了幾次"))
        XCTAssertTrue(ClauseRules.isQuestion("你試了幾次"), "問對方＝問句")
        XCTAssertTrue(ClauseRules.isQuestion("他們有沒有回信"), "沒有轉述詞＝問句")
    }

    /// 2026-09-19 實機「然，後我剛剛，靠卡好像又是只剩 300 多」：新引擎一字一段，停頓落在詞中間、句中遲疑都不能斷。
    func testNoBreakInsideWordOrOnHesitation() {
        let chars = ["然", "後", "我", "剛", "剛", "靠", "卡", "好", "像", "又", "是", "只", "剩"]
        var t = 0.0
        var tokens: [TimedToken] = []
        for (i, c) in chars.enumerated() {
            if i == 1 { t += 0.3 }          // 「然…後」遲疑
            if i == 5 { t += 0.3 }          // 「剛剛…靠卡」遲疑
            tokens.append(tok(c, t, 0.15)); t += 0.15
        }
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "然後我剛剛靠卡好像又是只剩")
    }

    /// 實機「就除值了今天，又說」：停頓在「了」前面，斷點要挪到「了」後面。
    func testBreakDeferredPastParticle() {
        let tokens = [tok("我", 0.0), tok("上次", 0.2), tok("坐車", 0.45), tok("之前", 0.7), tok("就", 0.95), tok("儲值", 1.15),
                      tok("了", 1.9),                                         // 停 0.55 在「了」前
                      tok("今天", 2.1), tok("又", 2.35), tok("說", 2.55), tok("沒有", 2.75), tok("錢", 3.0), tok("了", 3.2)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "我上次坐車之前就儲值了，今天又說沒有錢了")
    }

    /// 2026-09-19 實機：「搭到。中正紀念堂」「7:4。12」「原。山站」
    func testNoBreakAfterDanglingWordInsideNumberOrMidWordEnginePunct() {
        let t1 = [tok("然後", 0.0), tok("再", 0.25), tok("搭到", 0.5), tok("中正紀念堂", 1.4)]      // 停 0.7 但停在「搭到」
        XCTAssertEqual(PausePunctuator.punctuate(t1), "然後再搭到中正紀念堂")
        let t2 = [tok("大概", 0.0), tok("7:4", 0.3), tok("2", 1.1)]                              // 數字中間停 0.6
        XCTAssertEqual(PausePunctuator.punctuate(t2), "大概7:42")
        let t3 = [tok("搭到", 0.0), tok("原。", 0.25), tok("山", 0.5), tok("站", 0.7)]              // 引擎插在詞中間的句號
        XCTAssertEqual(PausePunctuator.punctuate(t3), "搭到原山站")
    }

    func testParticleEndedShortClauseStillBreaks() {
        let tokens = [tok("好", 0.0), tok("啊", 0.2), tok("我", 1.2), tok("等", 1.4), tok("你", 1.6)]   // 停 0.8，「好啊」語助詞收尾 → 逗號
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "好啊，我等你")
    }

    /// 2026-09-24 Mac 真 SpeechTranscriber（美佳合成，句中停 0.9–1.2 s）：舊規則「我覺得這個方案。可能還要再。想一下」。
    func testThinkingPausesNeverBecomePeriods() {
        let chars = Array("我覺得這個方案可能還要再想一下因為預算的部分還沒有確定")
        var t = 0.0
        var tokens: [TimedToken] = []
        for (i, c) in chars.enumerated() {
            if i == 7 || i == 12 || i == 22 { t += 1.1 }    // 方案…可能、還要再…想一下、預算的部分…還沒有
            tokens.append(tok(String(c), t, 0.15)); t += 0.15
        }
        let out = PausePunctuator.punctuate(tokens)
        XCTAssertFalse(out.contains("。"), out)
        XCTAssertFalse(out.contains("再，"), "停在「再」＝還在想下一個詞：\(out)")
        XCTAssertEqual(out, "我覺得這個方案，可能還要再想一下，因為預算的部分，還沒有確定")
    }

    /// 開頭的「那個…」「然後…」這種短遲疑，停再久都不斷。
    func testShortLeadInHesitationNeverBreaks() {
        let tokens = [tok("那個", 0.0), tok("我", 1.6), tok("剛剛", 1.8), tok("有", 2.05), tok("跟他說", 2.25)]
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "那個我剛剛有跟他說")
    }

    /// 引擎自己在遲疑處插的句號（真 SpeechTranscriber：「你明天。有空嗎」）拿掉；完整句子的句號與句尾句號保留。
    func testEngineHesitationPeriodDropped() {
        XCTAssertEqual(PausePunctuator.dropHesitationPeriods("所以下午要再開一次會，你明天。有空嗎？"), "所以下午要再開一次會，你明天有空嗎？")
        XCTAssertEqual(PausePunctuator.dropHesitationPeriods("就是檔案要先傳給我。我再幫他看一下。"), "就是檔案要先傳給我。我再幫他看一下。")
        XCTAssertEqual(PausePunctuator.dropHesitationPeriods("好了。走吧。"), "好了。走吧。", "語助詞收尾的短句是完整的")
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
        XCTAssertEqual(PausePunctuator.punctuate(tokens), "send the stems by Friday, thanks", "短子句的停頓＝遲疑；英文長停頓也不補句號")
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
