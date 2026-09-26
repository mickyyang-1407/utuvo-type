import XCTest
@testable import UTUVOTypeCore

final class NormalizerTests: XCTestCase {

    // MARK: - 標點

    func testTrimsWhitespace() {
        let n = Normalizer()
        let out = n.normalize("   你好   ")
        XCTAssertEqual(out.cleaned, "你好")
    }

    func testNormalizesWesternCommaBetweenChineseToFullWidth() {
        let n = Normalizer()
        let out = n.normalize("你好,世界")
        XCTAssertEqual(out.cleaned, "你好，世界")
    }

    func testKeepsEnglishCommaUnchanged() {
        let n = Normalizer()
        let out = n.normalize("hello, world")
        XCTAssertEqual(out.cleaned, "hello, world")
    }

    // MARK: - 贅詞

    func testRemovesFillerNaGe() {
        let n = Normalizer()
        let out = n.normalize("那個我今天很累")
        XCTAssertEqual(out.cleaned, "我今天很累")
    }

    func testRemovesFillerEn() {
        let n = Normalizer()
        let out = n.normalize("嗯今天天氣不錯啊")
        XCTAssertEqual(out.cleaned, "今天天氣不錯啊", "句首「嗯」刪；句尾黏在字後的「啊」是語氣詞要留")
    }

    /// 2026-09-25 Micky 實機：「當然啊」被刪成「當然」。句尾語氣詞留，句首／單獨的「啊」「欸」照刪。
    func testKeepsSentenceFinalParticles() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("當然啊").cleaned, "當然啊")
        XCTAssertEqual(n.normalize("好啊，我等你").cleaned, "好啊，我等你")
        XCTAssertEqual(n.normalize("對啊，就是這樣").cleaned, "對啊，就是這樣")
        XCTAssertEqual(n.normalize("你要來嗎？好欸").cleaned, "你要來嗎？好欸")
        XCTAssertEqual(n.normalize("啊，我忘了帶硬碟").cleaned, "我忘了帶硬碟")
        XCTAssertEqual(n.normalize("欸 你看這個").cleaned, "你看這個")
    }

    /// 2026-09-17 鍵盤實測：「在錄音室對 Atmos 母帶」的「對」被當贅詞刪掉（右邊是空白就算邊界）。
    func testKeepsDuiAsPrepositionBeforeLatinWord() {
        XCTAssertEqual(Normalizer().normalize("明天在錄音室對 Atmos 母帶").cleaned, "明天在錄音室對 Atmos 母帶")
    }

    /// 同一條規則的另一面：句尾的「不對」原本會被刪成「不」。
    func testKeepsDuiInBuDui() {
        XCTAssertEqual(Normalizer().normalize("這個不對").cleaned, "這個不對")
    }

    func testStillRemovesStandaloneDui() {
        XCTAssertEqual(Normalizer().normalize("對，明天見").cleaned, "明天見")
        XCTAssertEqual(Normalizer().normalize("好，對，就這樣").cleaned, "好，就這樣")
    }

    /// 「這個／那個」夾在中文與英文之間是實詞，不是贅詞。
    func testKeepsZheGeBeforeLatinWord() {
        XCTAssertEqual(Normalizer().normalize("我要用這個 app 記筆記").cleaned, "我要用這個 app 記筆記")
    }

    /// 簡體：同一套規則（該刪的刪、實詞留著）。
    func testSimplifiedFillers() {
        XCTAssertEqual(Normalizer().normalize("那个我今天很累").cleaned, "我今天很累")
        XCTAssertEqual(Normalizer().normalize("对，明天见").cleaned, "明天见")
        XCTAssertEqual(Normalizer().normalize("这个不对").cleaned, "这个不对")
        XCTAssertEqual(Normalizer().normalize("明天在录音室对 Atmos 母带").cleaned, "明天在录音室对 Atmos 母带")
        XCTAssertEqual(Normalizer().normalize("我要用这个 app 记笔记").cleaned, "我要用这个 app 记笔记")
    }

    func testFillerStageIsRecorded() {
        let n = Normalizer()
        let out = n.normalize("那個我今天很累")
        XCTAssertTrue(out.appliedSteps.contains("filler"))
    }

    // MARK: - 重複

    func testCollapsesRepeatedTokens() {
        let n = Normalizer()
        let out = n.normalize("我我覺得這樣這樣不好")
        XCTAssertEqual(out.cleaned, "我覺得這樣不好")
    }

    func testCollapsesStutterSeparatedByPauseMarkers() {
        XCTAssertEqual(Normalizer.collapseRepeats("我、我、我想明天再確認"), "我想明天再確認")
        XCTAssertEqual(Normalizer.collapseRepeats("明天先，明天先確認"), "明天先確認")
        XCTAssertEqual(Normalizer.collapseRepeats("我想看看報告。看看有沒有錯"), "我想看看報告。看看有沒有錯")
    }

    func testKeepsIntentionallyRepeatedCharacter() {
        // "看看" 不是語音重複 bug，不應被壓。
        let n = Normalizer()
        let out = n.normalize("我想看看報告")
        XCTAssertEqual(out.cleaned, "我想看看報告")
    }

    // MARK: - 自修正

    func testSelfCorrectionBuShiAY() {
        let n = Normalizer()
        let out = n.normalize("明天不是週一，是週二開會")
        XCTAssertEqual(out.cleaned, "明天週二開會")
    }

    func testSelfCorrectionKeepsCopulaAfterSubject() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("這不是我的，是他的").cleaned, "這是他的")
        XCTAssertEqual(n.normalize("我不是生氣，是累了").cleaned, "我是累了")
        XCTAssertEqual(n.normalize("明天不是週一，是週二開會").cleaned, "明天週二開會", "時間詞後面不用補是")
    }

    func testSelfCorrectionGaiCheng() {
        let n = Normalizer()
        let out = n.normalize("改成下週三開會")
        XCTAssertEqual(out.cleaned, "下週三開會")
    }

    // MARK: - 數字 / 日期 / 時間 / 金額

    func testDateYearMonthDayNormalized() {
        let n = Normalizer()
        let out = n.normalize("二〇二六年八月十七日開會")
        XCTAssertEqual(out.cleaned, "2026 年 8 月 17 日開會")
    }

    func testTimeBan() {
        let n = Normalizer()
        let out = n.normalize("五點半出門")
        XCTAssertEqual(out.cleaned, "5:30出門")
    }

    func testTimeHourOnly() {
        let n = Normalizer()
        let out = n.normalize("三點開會")
        XCTAssertEqual(out.cleaned, "3:00開會")
    }

    func testAmountWithWan() {
        let n = Normalizer()
        let out = n.normalize("預算一百二十萬元")
        XCTAssertEqual(out.cleaned, "預算1,200,000元")
    }

    func testAmountSimple() {
        let n = Normalizer()
        let out = n.normalize("一百二十三元")
        XCTAssertEqual(out.cleaned, "123元")
    }

    func testChineseToIntKnownValues() {
        XCTAssertEqual(Normalizer.chineseToInt("一"), 1)
        XCTAssertEqual(Normalizer.chineseToInt("十二"), 12)
        XCTAssertEqual(Normalizer.chineseToInt("十五"), 15)
        XCTAssertEqual(Normalizer.chineseToInt("一百二十三"), 123)
        XCTAssertEqual(Normalizer.chineseToInt("三千五百"), 3500)
        XCTAssertEqual(Normalizer.chineseToInt("二〇二六"), 2026)
        XCTAssertEqual(Normalizer.chineseToInt("一百二十萬"), 1_200_000)
        XCTAssertNil(Normalizer.chineseToInt(""))
        XCTAssertNil(Normalizer.chineseToInt("蘋果"))
    }

    func testFormatThousands() {
        XCTAssertEqual(Normalizer.formatThousands(0), "0")
        XCTAssertEqual(Normalizer.formatThousands(999), "999")
        XCTAssertEqual(Normalizer.formatThousands(1000), "1,000")
        XCTAssertEqual(Normalizer.formatThousands(1234567), "1,234,567")
    }

    // MARK: - 字典

    func testDictionaryLongestFirst() {
        let opts = NormalizerOptions(dictionary: [
            "台藝大": "台灣藝術大學",
            "藝大": "藝術大學"  // 短詞不該先匹配
        ])
        let n = Normalizer(options: opts)
        let out = n.normalize("我去台藝大")
        XCTAssertEqual(out.cleaned, "我去台灣藝術大學")
    }

    func testDictionaryBoundary() {
        let opts = NormalizerOptions(dictionary: ["蘋果": "apple"])
        let n = Normalizer(options: opts)
        // 「蘋果派」不該被改成 "apple派"
        let out = n.normalize("我買了蘋果派")
        XCTAssertEqual(out.cleaned, "我買了蘋果派")
    }

    func testDictionaryLatinTermGluedToCJK() {
        let n = Normalizer(options: NormalizerOptions(dictionary: ["pik": "Pik"]))
        // 語音辨識把英文黏在中文前後：中文是邊界
        XCTAssertEqual(n.normalize("我在用pik播放器").cleaned, "我在用Pik播放器")
        XCTAssertEqual(n.normalize("pik很好用").cleaned, "Pik很好用")
    }

    func testDictionaryLatinTermInsideLongerWord() {
        let n = Normalizer(options: NormalizerOptions(dictionary: ["pik": "Pik"]))
        // 右側或左側還是拼音文字＝更長的詞，保留原文
        XCTAssertEqual(n.normalize("我抓到pika了").cleaned, "我抓到pika了")
        XCTAssertEqual(n.normalize("看apik這個字").cleaned, "看apik這個字")
        XCTAssertEqual(n.normalize("檔名pik2要改").cleaned, "檔名pik2要改")
    }

    // MARK: - 清單線索

    func testListCueFirstSecondThird() {
        let n = Normalizer()
        let out = n.normalize("第一買牛奶第二回email第三寫報告")
        XCTAssertTrue(out.cleaned.contains("\n"))
        XCTAssertTrue(out.cleaned.contains("第一買牛奶"))
        XCTAssertTrue(out.cleaned.contains("第二回email"))
        XCTAssertTrue(out.cleaned.contains("第三寫報告"))
    }

    func testListCueSkippedWhenMarkdown() {
        let n = Normalizer()
        let out = n.normalize("- 第一點\n- 第二點")
        // markdown 結構保留，不應被加 newline 拆開
        XCTAssertFalse(out.cleaned.contains("\n第一"))
    }

    // MARK: - Pipeline sentinel

    func testAllStagesAreRecorded() {
        let n = Normalizer()
        let out = n.normalize("嗯那個明天三點半開會不是三點是四點")
        let expectedStages = ["trim", "spelled-letters", "filler", "repeat", "self-correction", "number-date-amount", "list", "punctuation", "particles", "collapse-whitespace", "paragraph"]
        for stage in expectedStages {
            XCTAssertTrue(out.appliedSteps.contains(stage), "missing stage \(stage) in \(out.appliedSteps)")
        }
    }

    // MARK: - 逐字母縮寫（2026-09-19 實機：「K C F S在哪裡呀？」）

    func testSpelledLettersJoin() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("K C F S在哪裡呀？").cleaned, "KCFS在哪裡呀？")
        XCTAssertEqual(n.normalize("我們交 A D M 檔").cleaned, "我們交 ADM 檔")
        XCTAssertEqual(n.normalize("plan A 跟 plan B").cleaned, "plan A 跟 plan B")
        XCTAssertEqual(n.normalize("I am fine").cleaned, "I am fine")
    }

    func testSpelledLettersFeedDictionary() {
        let n = Normalizer(options: NormalizerOptions(dictionary: ["KCFS": "KCFS 國際學校"]))
        XCTAssertEqual(n.normalize("K C F S在哪裡").cleaned, "KCFS 國際學校在哪裡")
    }

    // MARK: - 句尾語助詞（2026-09-19 實機：「我現在在慢慢走過去學校，了」）

    func testParticlesReattach() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("我現在在慢慢走過去學校，了").cleaned, "我現在在慢慢走過去學校了")
        XCTAssertEqual(n.normalize("我到學校。了").cleaned, "我到學校了。")
        XCTAssertEqual(n.normalize("好，啦，那我們走吧").cleaned, "好啦，那我們走吧")
        XCTAssertEqual(n.normalize("你到了，嗎？").cleaned, "你到了嗎？")
        XCTAssertEqual(n.normalize("我了解，了解你的意思").cleaned, "我了解，了解你的意思", "了解不是語助詞")
        XCTAssertEqual(n.normalize("吃飯了，我們走").cleaned, "吃飯了，我們走")
    }

    // 新引擎輸出格式（2026-09-19）
    func testNoSpaceBeforeFullWidthPunctuation() {
        XCTAssertEqual(Normalizer().normalize("老師你好 ，我是上週來上課的同學 ，謝謝").cleaned, "老師你好，我是上週來上課的同學，謝謝")
    }

    func testOnlyMisconvertedAsMeasureWord() {
        XCTAssertEqual(TaiwanPhrases.apply("還是隻要交立體聲版本"), "還是只要交立體聲版本")
        XCTAssertEqual(TaiwanPhrases.apply("我隻是問問，不隻這樣"), "我只是問問，不只這樣")
        XCTAssertEqual(TaiwanPhrases.apply("這隻要多少錢"), "這隻要多少錢", "量詞「這隻」不能改")
        XCTAssertEqual(TaiwanPhrases.apply("一隻貓"), "一隻貓")
    }

    // 2026-09-19 實機：「我就搞不懂。哎。」
    func testTrailingInterjectionJoinsSentence() {
        XCTAssertEqual(Normalizer().normalize("只剩 300 多，我就搞不懂。哎。").cleaned, "只剩 300 多，我就搞不懂，哎。")
        XCTAssertEqual(Normalizer().normalize("好累。唉").cleaned, "好累，唉。")
        XCTAssertEqual(Normalizer().normalize("哎，今天好累。").cleaned, "哎，今天好累。", "開頭的不動")
    }

    func testCommonMisspellings() {
        XCTAssertEqual(TaiwanPhrases.apply("悠悠卡自動除值，你因該知道"), "悠悠卡自動儲值，你應該知道")
        XCTAssertEqual(TaiwanPhrases.apply("這個原因該怎麼解釋"), "這個原因該怎麼解釋", "原因＋該 不是錯字")
        XCTAssertEqual(TaiwanPhrases.apply("以經驗來說"), "以經驗來說")
    }

    // MARK: - 改口與時間（2026-09-19 實機）

    func testCorrectionMarkerAfterPause() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("而且你看我上次做完，應該說我上次坐車之前就儲值了").cleaned, "而且你看我上次坐車之前就儲值了")
        XCTAssertEqual(n.normalize("我們約禮拜三，我是說禮拜四下午").cleaned, "我們約禮拜四下午")
        XCTAssertEqual(n.normalize("我應該說實話").cleaned, "我應該說實話", "沒停頓＝不是改口")
    }

    func testRepairAfterFiller() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("我是剛上去哦剛出門要搭937").cleaned, "我是剛出門要搭937")
        XCTAssertEqual(n.normalize("我先走哦我明天再來").cleaned, "我先走哦我明天再來", "人稱開頭不當改口")
        XCTAssertEqual(n.normalize("好喔好的").cleaned, "好喔好的", "喔不收")
    }

    func testDecimalTimes() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("1000他是寫 5.49，但是 5.49的時候我剛出門").cleaned, "1000他是寫 5:49，但是 5:49的時候我剛出門")
        XCTAssertEqual(n.normalize("下午 3.15 開會").cleaned, "下午 3:15 開會")
        XCTAssertEqual(n.normalize("這杯 5.49 美元").cleaned, "這杯 5.49 美元", "金額不動")
        XCTAssertEqual(n.normalize("版本 2.10 更新了").cleaned, "版本 2.10 更新了")
    }

    func testNoSpaceAfterFullWidthPunctuation() {
        XCTAssertEqual(Normalizer().normalize("好， 1000他是寫的").cleaned, "好，1000他是寫的")
    }

    // 2026-09-19 實機「大概 7:4。12到」：辨識器把「七點四十二」拆開
    func testSplitMinutesRejoined() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("我是下午 5:49出門的，然後大概 7:4。12到").cleaned, "我是下午 5:49出門的，然後大概 7:42到")
        XCTAssertEqual(n.normalize("然後大概 7.40二到").cleaned, "然後大概 7:42到")
        XCTAssertEqual(n.normalize("版本 2.10 更新了").cleaned, "版本 2.10 更新了")
    }

    // 單獨的改口詞（Mac 實測 Apple 裝置端小模型會把這兩句方向弄反，所以用規則）
    func testStandaloneCorrectionWords() {
        let n = Normalizer()
        XCTAssertEqual(n.normalize("我們約禮拜三，不是，禮拜四下午三點在公司見。").cleaned, "我們約禮拜四下午3點在公司見。")
        XCTAssertEqual(n.normalize("我是剛上去，喔不對，剛出門要搭937。").cleaned, "我是剛出門要搭937。")
        XCTAssertEqual(n.normalize("但是不是應該都是 500嗎？").cleaned, "但是不是應該都是 500嗎？", "句中的「不是」不算")
    }
}
