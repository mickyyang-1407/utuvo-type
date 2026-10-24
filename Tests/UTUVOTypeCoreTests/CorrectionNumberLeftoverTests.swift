import XCTest
@testable import UTUVOTypeCore

/// FX-8（2026-10-23）：改口與數字的四個遺留缺陷（D1–D4），每一個都會給錯日子、金額或鐘點。
/// Kotlin `CorrectionNumberLeftoverTest` 逐條相同；另由 GoldenExportTests 匯出到 numbers.json
///（含 benchmarks/fx-eight-golden-corpus.txt＝差分閘門 fx-eight 的審查回報＋oracle 全部列＋新 fuzz 模板每 20 取 1）。
/// 第一次貼上＝`SentenceMood.finish(Normalizer().normalize(raw).cleaned)`（三個 app 送出前都這樣）。
final class CorrectionNumberLeftoverTests: XCTestCase {
    /// D1 緊跟在「星期／禮拜／礼拜／週／周」後面的數字是星期幾，不是鐘點的一部分：改口只換鐘點，星期幾不變、不掉
    ///（以前「禮拜五三點，不對，四點」→「禮拜四點」、「週三十點，不對，十一點」→「週十一點」）。
    static let d1WeekdayDigitStaysWithTheWeekday: [(String, String)] = [
        ("禮拜五三點，不對，四點", "禮拜五4點"),
        ("禮拜五三點不對四點", "禮拜五4點"),
        ("星期二三點不對四點", "星期二4點"),
        ("下禮拜三五點，不對，六點", "下禮拜三6點"),
        ("礼拜五三點，不對，四點", "礼拜五四點"),
        ("周三兩點，不對，三點", "周三三點"),
        ("星期五一點，不對，兩點", "星期五2點"),
        ("禮拜一三點，不對，四點", "禮拜一4點"),
        ("這禮拜六九點，不對，十點", "這禮拜六10點"),
        ("週三十點，不對，十一點", "週三十一點"),
        ("週六兩點半，不對，三點", "週六3:00"),
        ("星期四八點半，不對，九點", "星期四9:00"),
        ("禮拜五四點，不是，一點", "禮拜五1點"),
        ("星期二十二點零五分不對一點", "星期二1:00"),
        ("禮拜一一點十五分，不對，兩點", "禮拜一2:00"),
        ("礼拜四二點半，我是說，五點", "礼拜四5:00"),
        // FX-6 的 t1UnreadableHourStaysAsSpoken 以前留著原話（把「五三」當鐘點讀不出來）；照 D1，鐘點是「三點半」。
        ("禮拜五三點半，不對，四點", "禮拜五4:00"),
        // 新值帶著星期幾、舊值沒有：星期幾不能被讀進鐘點（以前「我們五四點」），對不上＝整句照講的留著。
        ("我們三點，不對，禮拜五四點", "我們三點，不對，禮拜五4點"),
    ]

    /// D1 反面：星期換星期、沒有星期幾、每週幾個（不是鐘點）照舊。
    static let d1Guards: [(String, String)] = [
        ("禮拜五，不對，禮拜六", "禮拜六"),
        ("禮拜五三點，不對，禮拜六三點", "禮拜六3點"),
        ("我們三點，不對，四點", "我們四點"),
        ("明天三點，不對，四點", "明天4點"),
        ("禮拜五下午三點，不對，四點", "禮拜五下午4點"),
        ("週日十點，不對，十一點", "週日十一點"),
        ("每週三十個，不對，四十個", "每週四十個"),
        ("一個禮拜三十個小時，不對，四十個小時", "一個禮拜四十個小時"),
    ]

    /// D1 數字關：「礼拜」（簡體）跟「禮拜」一樣，星期幾不併進鐘點（以前「礼拜四二點半」→「礼拜42:30」）。
    static let d1SimplifiedLibaiNumbers: [(String, String)] = [
        ("礼拜四二點半", "礼拜四2:30"),
        ("礼拜五十點十五分開會", "礼拜五10:15開會"),
        ("禮拜四二點半", "禮拜四2:30"),
    ]

    /// D2 改口不落在它沒有換掉的小數裡面：小數＋位值是一整個值，跟小數對齊（一點二萬 → 一點五萬）；
    /// 小數對整數對不上＝整句照講的留著（以前「還差一點五萬，不對，還差兩萬」→「還差一點20,000」、「兩點五萬，不對，三萬」→「23,000」）。
    static let d2CorrectionNeverLandsInsideADecimal: [(String, String)] = [
        ("還差一點五萬，不對，還差兩萬", "還差15,000，不對，還差20,000"),
        ("還差一點五萬不對兩萬", "還差15,000不對20,000"),
        ("大概一點五萬，不對，兩萬", "大概15,000，不對，20,000"),
        ("還差三點五萬，不對，四萬", "還差35,000，不對，40,000"),
        ("兩點五萬，不對，三萬", "25,000，不對，30,000"),
        ("預算一萬，不對，一點五萬", "預算10,000，不對，15,000"),
        ("預算一點二萬，不對，一點五萬", "預算15,000"),
        ("一點五萬，不對，一點八萬", "18,000"),
        ("總共兩點三萬，不對，兩點八萬", "總共28,000"),
        ("差不多一點五萬，不對，一點八萬", "差不多18,000"),
        ("一點二萬，不對，兩點五萬", "25,000"),
        ("還差一點一萬，不是，兩點二萬", "還差22,000"),
        ("還差一點一千，我是說，兩點八千", "還差兩點八千"),
    ]

    /// D2 反面：整數換整數照舊。
    static let d2Guards: [(String, String)] = [
        ("還差兩萬，不對，還差三萬", "還差30,000"),
        ("預算一萬，不對，兩萬", "預算20,000"),
        ("還差一點五萬就達標", "還差15,000就達標"),
    ]

    /// D3 小數＋百不轉一半（以前「一點500元」）：整段照講的留著；比較用的「一點」也一樣。小數點後面不念「兩」照舊轉。
    static let d3DecimalHundredNeverHalfConverted: [(String, String)] = [
        ("一點五百元", "一點五百元"),
        ("這個一點五百塊", "這個一點五百塊"),
        ("兩點五百公尺", "兩點五百公尺"),
        ("三點五百元", "三點五百元"),
        ("差一點五百塊", "差一點五百塊"),
        ("再便宜一點五百塊就好", "再便宜一點五百塊就好"),
        ("下午三點五百人參加", "下午三點五百人參加"),
        ("一點五百萬", "一點五百萬"),
        ("五百元", "500元"),
        ("一百五十元", "150元"),
        ("三點兩百塊", "三點200塊"),
        ("一點五萬", "15,000"),
    ]

    /// D4 舊值有兩種讀法（小數＋萬／千／百，或鐘點＋金額）、新值只合其中一種（整點）＝不改，整句照講的留著
    ///（以前「三點一萬塊，不對，四點」→「四點10,000塊」、「兩點五萬，不對，三點」→「35,000」）。
    static let d4AmbiguousOldValueDeclines: [(String, String)] = [
        ("三點一萬塊，不對，四點", "三點10,000塊，不對，四點"),
        ("三點一萬塊不對四點", "三點10,000塊不對四點"),
        ("兩點五萬，不對，三點", "25,000，不對，三點"),
        ("一點五萬，不對，兩點", "15,000，不對，兩點"),
        ("三點五千，不對，四點", "三點五千，不對，四點"),
        ("預算兩點八百，不對，兩點", "預算兩點八百，不對，兩點"),
        ("一點三百，不是，四點", "一點三百，不是，四點"),
    ]

    /// D4 反面：鐘點換鐘點（FX-6）照舊。
    static let d4Guards: [(String, String)] = [
        ("三點，不對，四點", "四點"),
        ("三點半，不對，四點", "4:00"),
        ("三點一萬塊", "三點10,000塊"),
    ]

    static let firstPasteCases = d1WeekdayDigitStaysWithTheWeekday + d1Guards + d1SimplifiedLibaiNumbers
        + d2CorrectionNeverLandsInsideADecimal + d2Guards + d3DecimalHundredNeverHalfConverted
        + d4AmbiguousOldValueDeclines + d4Guards
    /// GoldenExportTests 把這些放進 numbers.json。
    static let goldenInputs = firstPasteCases.map(\.0)

    private func firstPaste(_ raw: String) -> String {
        SentenceMood.finish(Normalizer().normalize(raw).cleaned)
    }

    private func check(_ cases: [(String, String)]) {
        for (raw, expected) in cases { XCTAssertEqual(firstPaste(raw), expected, raw) }
    }

    func testD1WeekdayDigitStaysWithTheWeekday() { check(Self.d1WeekdayDigitStaysWithTheWeekday) }
    func testD1Guards() { check(Self.d1Guards) }
    func testD1SimplifiedLibaiNumbers() { check(Self.d1SimplifiedLibaiNumbers) }
    func testD2CorrectionNeverLandsInsideADecimal() { check(Self.d2CorrectionNeverLandsInsideADecimal) }
    func testD2Guards() { check(Self.d2Guards) }
    func testD3DecimalHundredNeverHalfConverted() { check(Self.d3DecimalHundredNeverHalfConverted) }
    func testD4AmbiguousOldValueDeclines() { check(Self.d4AmbiguousOldValueDeclines) }
    func testD4Guards() { check(Self.d4Guards) }

    /// D3 在數字關本身（也跑在每一個 LLM 輸出上）也一樣，而且再整理一次不變。
    func testD3HoldsInNormalizeNumbersAndIsIdempotent() {
        for raw in ["一點五百元", "兩點五百公尺", "差一點五百塊", "再便宜一點五百塊就好", "一點五百萬", "這台一點五百瓦"] {
            let once = Normalizer.normalizeNumbers(raw)
            XCTAssertEqual(once, raw, raw)
            XCTAssertEqual(Normalizer.normalizeNumbers(once), once, raw)
        }
    }

    /// 每一個 D1 改口的結果都還帶著原本那個星期幾（「禮拜五」不會變成「禮拜」或「禮拜四」）。
    func testD1ResultKeepsTheSpokenWeekday() {
        for (raw, _) in Self.d1WeekdayDigitStaysWithTheWeekday where !raw.hasPrefix("我們") {
            let weekday = raw.range(of: "(?:星期|禮拜|礼拜|週|周)[一二三四五六日天]", options: .regularExpression).map { String(raw[$0]) }
            XCTAssertNotNil(weekday, raw)
            XCTAssertTrue(firstPaste(raw).contains(weekday ?? "?"), raw)
        }
    }
}
