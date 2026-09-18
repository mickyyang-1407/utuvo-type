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
        XCTAssertEqual(out.cleaned, "今天天氣不錯")
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
        let expectedStages = ["trim", "filler", "repeat", "self-correction", "number-date-amount", "list", "punctuation", "collapse-whitespace"]
        for stage in expectedStages {
            XCTAssertTrue(out.appliedSteps.contains(stage), "missing stage \(stage) in \(out.appliedSteps)")
        }
    }
}
