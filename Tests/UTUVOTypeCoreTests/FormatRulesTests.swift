import XCTest
@testable import UTUVOTypeCore

/// 2026-10-22 Typeless 對打（cleanup-format／cleanup-semantics）：數字、單位、金額、標點、電話的 deterministic 規則。
/// 每條規則都同時驗「該改」與「不該改」兩張清單。Kotlin 鏡像：android/core/src/test/kotlin/com/utuvo/type/core/FormatRulesTest.kt，
/// 案例逐字相同；整條 normalize 管線另由 `goldenInputs` 進 Swift→Kotlin 標準答案。
final class FormatRulesTests: XCTestCase {
    /// GoldenExportTests 會把這些丟進整條 normalize 管線、匯出給 Kotlin 逐條比對。
    static let goldenInputs = [
        "預算是30萬，第二期先付10萬5",
        "預算是 30 萬，第二期先付 10 萬 5000 塊",
        "AIFC，二十四bit，離散的九十六kHz",
        "響度對齊到負十四 LUFS，True Peak 負一 dBTP",
        "取樣率用九十六K",
        "唯一 K 歌的地方",
        "總共是1250 塊",
        "Utuvo Type,在手機上面叫做Utuvo Type,被搞混了",
        "重開一個Session?",
        "響度對齊到 -14 LUFS,\n第二個問題",
        "我的電話是零九一二三四五六七八，市話0223333333",
        "金額是一萬二，不對，是一萬兩千塊。",
        "金額是一萬二，不對，一萬五",
    ]

    // MARK: - cleanup-format-1(a)：阿拉伯數字＋萬／億 → 完整數值

    func testArabicWanYiBecomesFullValue() {
        let cases: [(String, String)] = [
            ("30萬", "300,000"),
            ("10萬5", "105,000"),           // 一位數尾巴＝口語省略單位（十萬五）
            ("1.5萬", "15,000"),
            ("10萬5000", "105,000"),        // 多位數尾巴＝照字面
            ("30 萬", "300,000"),
            ("3萬2千", "32,000"),
            ("30萬元", "300,000元"),
            ("10萬5 塊", "105,000 塊"),
            ("3億", "300,000,000"),
            ("2億5", "250,000,000"),
            ("3億5000萬", "350,000,000"),
            ("預算是30萬，第二期先付10萬5", "預算是300,000，第二期先付105,000"),
        ]
        for (input, expected) in cases { XCTAssertEqual(Normalizer.normalizeNumbers(input), expected, input) }
    }

    func testArabicWanYiLeavesOtherShapesAlone() {
        for input in ["三樓", "3:30", "1. 播放器", "千萬不要", "3萬五千", "存了3萬一直沒用", "3億5000", "3億2千萬",
                      "1,000萬", "10萬5.5", "1.55555萬", "10萬5,000", "30萬 2026年"] {
            XCTAssertEqual(Normalizer.normalizeNumbers(input), input, input)
        }
        // 隔一個空白的數字分不出是尾巴還是下一個數：不能讀成兩個數（100,000 5,000）或錯位（105,000,000）。
        let spaced = Normalizer.normalizeNumbers("先付 10 萬 5000 塊")
        XCTAssertFalse(spaced.contains("100,000") || spaced.contains("105,000,000"), spaced)
    }

    /// 同一個值兩邊寫法不同（「三十萬」vs「30 萬」、「一點五萬」vs「1.5萬」）：正規化後要一樣，閘門才不會誤擋。
    func testArabicWanYiAgreesWithChineseNumerals() {
        XCTAssertEqual(Normalizer.normalizeNumbers("三十萬"), Normalizer.normalizeNumbers("30 萬"))
        XCTAssertEqual(Normalizer.normalizeNumbers("一點五萬"), Normalizer.normalizeNumbers("1.5萬"))
        XCTAssertEqual(Normalizer.normalizeNumbers(Normalizer.normalizeNumbers("一點五萬")), Normalizer.normalizeNumbers("一點五萬"))
    }

    // MARK: - cleanup-format-2：中文數字＋技術單位、負數

    func testChineseNumeralsBeforeTechnicalUnits() {
        let cases: [(String, String)] = [
            ("九十六 kHz", "96 kHz"),
            ("九十六kHz", "96kHz"),
            ("二十四 bit", "24 bit"),
            ("負十四 LUFS", "-14 LUFS"),
            ("九十六K", "96K"),
            ("四十八點一 kHz", "48.1 kHz"),
            ("負一 dBTP", "-1 dBTP"),
            ("三百二十 kbps", "320 kbps"),
            ("AIFC，二十四bit，離散的九十六kHz", "AIFC，24bit，離散的96kHz"),
            ("響度對齊到負十四 LUFS", "響度對齊到-14 LUFS"),
        ]
        for (input, expected) in cases { XCTAssertEqual(Normalizer.normalizeNumbers(input), expected, input) }
    }

    func testTechnicalUnitRuleLeavesWordsAlone() {
        for input in ["三樓", "一小時", "三件事", "第二個部分", "九十六", "K 歌", "唯一 K", "統一 dB", "之一 ms",
                      "九十六\nK", "負責九十六", "十五 Kelvin"] {
            XCTAssertEqual(Normalizer.normalizeNumbers(input), input, input)
        }
    }

    // MARK: - cleanup-format-6：金額與 塊／元 之間有空白

    func testMoneyWithSpaceBeforeUnitGetsSeparator() {
        let cases: [(String, String)] = [
            ("1250 塊", "1,250 塊"),
            ("1250塊", "1,250塊"),
            ("12000 元", "12,000 元"),
            ("總共是1250 塊", "總共是1,250 塊"),
            ("1250\u{00A0}元", "1,250\u{00A0}元"),
        ]
        for (input, expected) in cases { XCTAssertEqual(Normalizer.normalizeNumbers(input), expected, input) }
    }

    func testMoneyRuleDoesNotCrossLinesOrTouchOtherNumbers() {
        for input in ["2026 年", "第 1250 號", "3 塊錢", "1250\n塊", "清單 1250\n元件"] {
            XCTAssertEqual(Normalizer.normalizeNumbers(input), input, input)
        }
    }

    // MARK: - cleanup-format-v1：英文字／數字後面的半形 , ; ! ? 在中文裡轉全形

    func testHalfWidthPunctuationAfterLatinInsideChinese() {
        let cases: [(String, String)] = [
            ("Utuvo Type,在手機", "Utuvo Type，在手機"),
            ("2比1,不要", "2比1，不要"),
            ("重開一個Session?", "重開一個Session？"),
            ("Tim,大家好", "Tim，大家好"),
            ("OK!我們走", "OK！我們走"),
            ("用 Pro Tools ; 不要用 Logic", "用 Pro Tools；不要用 Logic"),
            ("Utuvo Type, 在手機", "Utuvo Type，在手機"),
            ("響度對齊到 -14 LUFS,\n第二個問題", "響度對齊到 -14 LUFS，\n第二個問題"),
            ("你有用 Atmos 嗎 OK?", "你有用 Atmos 嗎 OK？"),
        ]
        for (input, expected) in cases { XCTAssertEqual(Normalizer.normalizePunctuation(input), expected, input) }
    }

    func testHalfWidthPunctuationLeftAloneOutsideChinese() {
        for input in ["1,250塊", "v0.2.1", "3:30", "2:1", "Hello, world", "Are you OK?", "Hello, world\n你好",
                      "版本 v0.2.1 已上線", "時間 3:30 見", "比例 2:1 就好", "Hi,\n你好"] {
            XCTAssertEqual(Normalizer.normalizePunctuation(input), input, input)
        }
    }

    // MARK: - cleanup-format-v2：台灣電話號碼

    func testTaiwanPhoneNumbersAreFormatted() {
        let cases: [(String, String)] = [
            ("0912345678", "0912-345-678"),
            ("零九一二三四五六七八", "0912-345-678"),
            ("0912-345678", "0912-345-678"),
            ("0912 345 678", "0912-345-678"),
            ("0223333333", "02-2333-3333"),
            ("02-23333333", "02-2333-3333"),
            ("我的電話是0912345678，市話0223333333", "我的電話是0912-345-678，市話02-2333-3333"),
        ]
        for (input, expected) in cases { XCTAssertEqual(Normalizer.normalizeNumbers(input), expected, input) }
    }

    func testOtherDigitRunsAreNotPhoneNumbers() {
        for input in ["09123456789", "20260913", "1,250", "3:30", "0312345678", "A0912345678", "3.0912345678"] {
            XCTAssertEqual(Normalizer.normalizeNumbers(input), input, input)
        }
    }

    /// 兩個閘門兩邊都跑 normalizeNumbers：LLM 把電話排成 0912-345-678 不能再被嚴格閘門整段擋掉。
    func testStrictGateAcceptsFormattedPhone() {
        XCTAssertNil(CleanupFidelity.rejectionReason(original: "我的電話是0912345678", cleaned: "我的電話是 0912-345-678"))
        XCTAssertNil(CleanupFidelity.rejectionReason(original: "我的電話是零九一二三四五六七八", cleaned: "我的電話是 0912-345-678"))
        XCTAssertNil(CleanupFidelity.rejectionReason(original: "電話0912-345678", cleaned: "電話 0912-345-678"))
        XCTAssertNil(CleanupFidelity.rejectionReason(original: "市話02-23333333", cleaned: "市話 02-2333-3333"))
        // 真的改了號碼還是要擋
        XCTAssertNotNil(CleanupFidelity.rejectionReason(original: "我的電話是0912345678", cleaned: "我的電話是 0912-345-679"))
    }

    // MARK: - cleanup-semantics-2：改口裡的 萬／億 數字

    func testCorrectionWithWanKeepsSingleAmount() {
        XCTAssertEqual(Normalizer.applySelfCorrection("金額是一萬二，不對，是一萬兩千塊。"), "金額是一萬兩千塊。")
        XCTAssertEqual(Normalizer().normalize("金額是一萬二，不對，是一萬兩千塊。").cleaned, "金額是12,000塊。")
        XCTAssertEqual(Normalizer().normalize("金額是一萬二，不對，一萬五").cleaned, "金額是15,000")
        XCTAssertEqual(Normalizer.applySelfCorrection("三億，不對，四億"), "四億")
        XCTAssertEqual(Normalizer.applySelfCorrection("一億二，不對，一億五"), "一億五")
    }

    func testCorrectionWithoutWanUnchanged() {
        XCTAssertEqual(Normalizer.applySelfCorrection("一千二，不對，一千五"), "一千五")
        XCTAssertEqual(Normalizer.applySelfCorrection("三十萬，不對，三十五萬"), "三十五萬")
        XCTAssertEqual(Normalizer.applySelfCorrection("兩萬，不對，三萬"), "三萬")
        XCTAssertEqual(Normalizer.applySelfCorrection("金額是12000,不對,是12000塊。"), "金額是12000塊。")
        XCTAssertEqual(Normalizer.applySelfCorrection("我覺得一萬塊不對"), "我覺得一萬塊不對")
    }
}
