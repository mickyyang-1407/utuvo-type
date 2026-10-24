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

    /// 2026-10-22 bench fl03／ml02：「這個／那個」後面接英文或數字是限定詞，句首也要留。
    func testKeepsDemonstrativeBeforeLatinOrDigitAtClauseStart() {
        XCTAssertEqual(Normalizer().normalize("這個 delay 的尾巴是不是太長了？").cleaned, "這個 delay 的尾巴是不是太長了？")
        XCTAssertEqual(Normalizer().normalize("那個 compressor 的 ratio 調低一點").cleaned, "那個 compressor 的 ratio 調低一點")
        XCTAssertEqual(Normalizer().normalize("UTUVO 這個 App 很好用").cleaned, "UTUVO 這個 App 很好用")
        XCTAssertEqual(Normalizer().normalize("嗯，那個 compressor 的 ratio 調低一點").cleaned, "那個 compressor 的 ratio 調低一點")
        // 被逗號隔開的「那個」還是停頓贅詞，照刪。
        XCTAssertEqual(Normalizer().normalize("嗯，我覺得那個，就是，這個 low end 可以再收一點").cleaned,
                       "我覺得，就是，這個 low end 可以再收一點")
    }

    /// 句首贅詞串：有猶豫詞（嗯／呃／恩）或「就是說」、或「然後」後面緊接逗號才拿掉。
    func testStripsLeadingHesitationChains() {
        XCTAssertEqual(Normalizer().normalize("嗯嗯，然後就是說，我這邊沒有收到你的檔案喔。").cleaned, "我這邊沒有收到你的檔案喔。")
        XCTAssertEqual(Normalizer().normalize("然後然後，呃，高頻再收一點").cleaned, "高頻再收一點")
        XCTAssertEqual(Normalizer().normalize("然後然後呃高頻再收一點").cleaned, "高頻再收一點")
        XCTAssertEqual(Normalizer().normalize("恩恩，然後就是說，我這邊沒有收到你的檔案喔。").cleaned, "我這邊沒有收到你的檔案喔。")
        XCTAssertEqual(Normalizer().normalize("然後就是這樣。").cleaned, "然後就是這樣。", "沒有猶豫詞的「然後就是」不動")
    }

    /// 「恩」是「嗯」的錯字，但「感恩」「恩人」是實詞。
    func testEnIsAFillerOnlyWhenStandalone() {
        XCTAssertEqual(Normalizer().normalize("恩，我知道了").cleaned, "我知道了")
        XCTAssertEqual(Normalizer().normalize("感恩，謝謝").cleaned, "感恩，謝謝")
        XCTAssertEqual(Normalizer().normalize("恩人很好").cleaned, "恩人很好")
    }

    /// 贅詞和逗號中間隔著空白（iOS 停頓標點）也不留孤兒標點。
    func testNoOrphanCommaWhenWhitespaceSitsBetweenFillerAndComma() {
        XCTAssertEqual(Normalizer().normalize("嗯 ，我覺得那個就是這個 low end").cleaned, "我覺得那個就是這個 low end")
        XCTAssertEqual(Normalizer().normalize("好， 嗯，我覺得可以").cleaned, "好，我覺得可以")
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

    func testGaiChengRemainsInOrdinaryPhrase() {
        let n = Normalizer()
        let out = n.normalize("改成下週三開會")
        XCTAssertEqual(out.cleaned, "改成下週三開會")
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
        // 2026-10-22 W2-6 第三輪：第N 直接接動詞、又沒有「N件事／以下」引言＝不算清單，原文照留
        // （不換行、不編號）；有數量引言且數量對得上才編號。
        XCTAssertEqual(n.normalize("第一買牛奶第二回email第三寫報告").cleaned, "第一買牛奶第二回email第三寫報告")
        // 第四輪（2026-10-22）政策 (A)：每個「第N」要在子句開頭（前面是分隔或清單引言）——沒有標點連著講的序數串原樣
        //（第三輪這句會編號）；同一句有逗號就編號。
        XCTAssertEqual(n.normalize("今天有三件事第一買牛奶第二回email第三寫報告").cleaned, "今天有三件事第一買牛奶第二回email第三寫報告")
        let out = n.normalize("今天有三件事，第一買牛奶，第二回email，第三寫報告")
        XCTAssertTrue(out.cleaned.contains("\n"))
        // 2026-10-22 W2-6：連續的序數行改成編號清單（「第一」→「1. 」）。
        XCTAssertTrue(out.cleaned.contains("1. 買牛奶"))
        XCTAssertTrue(out.cleaned.contains("2. 回email"))
        XCTAssertTrue(out.cleaned.contains("3. 寫報告"))
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

    /// 改口詞後面沒停頓、Groq 小型標點（2026-10-22 sc03／sc04／sc05 真人錄音）：補逗號後對得齊才改。
    func testCorrectionsWithoutPauseAfterMarker() {
        let n = Normalizer()
        func done(_ s: String) -> String { SentenceMood.finish(s) }
        XCTAssertEqual(done(n.normalize("取樣利用48k﹐不對是96k﹐").cleaned), "取樣利用96k")
        XCTAssertEqual(done(n.normalize("幫我轉寄給小雅跟小柏﹑不是，是小雅跟小潘﹑").cleaned), "幫我轉寄給小雅跟小潘")
        XCTAssertEqual(done(n.normalize("檔名叫做Final V3，不對是Final V4").cleaned), "檔名叫做Final V4")
        XCTAssertEqual(done(n.normalize("明天三點不對四點開會").cleaned), "明天4:00開會")
        XCTAssertEqual(done(n.normalize("1200不對是12000").cleaned), "12000")
    }

    /// 對不齊、或「不對／不是」是在描述事情、或是對比句：一個字都不能動，也不能多出逗號。
    func testNonCorrectionsStayUntouched() {
        let n = Normalizer()
        for s in ["這樣不對是因為他沒來", "我覺得不對是正常的", "我住三樓，不是四樓", "萬一不是三點呢",
                  "我要的是48K不是96K", "我覺得這樣不對", "他說的不是，是我說的"] {
            XCTAssertEqual(n.normalize(s).cleaned, s, s)
        }
        // 對比句照樣不刪；同一句的兩個鐘點寫法一致（2026-10-22 W2-6 規則 8c，原本後一個留「四點」）。
        XCTAssertEqual(n.normalize("我們約三點開會，不是四點").cleaned, "我們約3:00開會，不是4:00")
        XCTAssertEqual(n.normalize("預算100萬，不是200萬").cleaned, "預算1,000,000，不是2,000,000")
        // 「不是 B 而是 A」是對比，不是改口（FX-3 第四輪 G3：原本切成「星期三而」）。
        XCTAssertEqual(n.normalize("不是星期四而是星期三").cleaned, "不是星期四而是星期三")
    }
}
