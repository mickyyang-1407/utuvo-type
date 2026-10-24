import XCTest
@testable import UTUVOTypeCore

/// FX-6（2026-10-23）：改口後的鐘點要換掉整個舊時間；幾種數字講法不能轉一半。Kotlin `ClockCorrectionNumberTest` 逐條相同，
/// 另由 GoldenExportTests 匯出到 numbers.json（含 benchmarks/fx-six-golden-corpus.txt＝差分閘門 fx-six 的審查回報＋oracle 全部列）。
/// 第一次貼上＝`SentenceMood.finish(Normalizer().normalize(raw).cleaned)`（三個 app 送出前都這樣）。
final class ClockCorrectionNumberTests: XCTestCase {
    /// T1 舊值是「N點＋分鐘」、新值只有整點 → 舊的分鐘一起換掉，寫成整點「H:00」（以前留著舊分鐘：4:30、4:15）。
    static let t1CorrectedClockReplacesTheWholeOldTime: [(String, String)] = [
        ("我們約三點半，不對，四點", "我們約4:00"),
        ("三點半不對四點", "4:00"),
        ("明天三點十五分，不對，四點", "明天4:00"),
        ("我們約兩點半，不是，三點", "我們約3:00"),
        ("下午兩點半，不對，三點", "下午3:00"),
        ("三點半開會，不對，四點", "4:00開會"),
        ("三點半，不對，四點開會", "4:00開會"),
        ("三點一刻，不對，四點", "4:00"),
        ("兩點四十，不對，三點", "3:00"),
        ("3點半，不對，4點", "4:00"),
        ("三點半，我是說四點", "4:00"),
        ("時間不是三點半是四點", "時間4:00"),
    ]

    /// T1 反面：新值自己有分鐘、或舊值沒有分鐘 → 照舊。
    static let t1NewMinutesOrNoOldMinutesUnchanged: [(String, String)] = [
        ("我們約三點，不對，四點半", "我們約4:30"),
        ("三點半，不對，四點半", "4:30"),
        ("三點半不對四點半", "4:30"),
        ("三點，不對，四點", "四點"),
        ("我們約三點，不對，四點", "我們約四點"),
        ("會議三點半，不對，四點十五分開始", "會議3:30，不對，4:15開始"),
    ]

    /// T1：讀不出舊的鐘點＝整句照講的留著，不會變成「禮拜4:30」。
    /// FX-8 D1 改了這條的期待值：星期幾後面那個數字屬於星期幾，「禮拜五三點半」的鐘點是「三點半」（以前當成讀不出來的「五三」），
    /// 所以改口照 T1 換成「禮拜五4:00」；真的讀不出來的鐘點（三十點半）照舊留著原話。
    static let t1UnreadableHourStaysAsSpoken: [(String, String)] = [
        ("禮拜五三點半，不對，四點", "禮拜五4:00"),
        ("禮拜五三十點半，不對，四點", "禮拜五三十點半，不對，四點"),
    ]

    /// T2 阿拉伯鐘點 H:MM 是一整個值（以前在「:」拆開：3:4:00、10:10:45）。
    static let t2ArabicClockIsOneValue: [(String, String)] = [
        ("3:30，不對，4:00", "4:00"),
        ("10:15，不對，10:45", "10:45"),
        ("我們約3:30，不對，4:00開會", "我們約4:00開會"),
        ("16:9，不對，4:3", "16:9，不對，4:3"),
        ("3:30不對4:00", "3:30不對4:00"),
    ]

    /// T3 normalizeNumbers 冪等：鐘點的數字不會被讀進後面的中文數字（以前第二次整理「11:30二萬」→「11:320,000」）。
    static let t3ClockDigitsNeverJoinTheNextNumber: [(String, String)] = [
        ("每週十一點半二萬就好", "每週11:30二萬就好"),
        ("每週11:30二萬就好", "每週11:30二萬就好"),
        ("11:32萬", "11:32萬"),
        ("十一點半二十個人", "11:30二十個人"),
        ("3:30一分鐘", "3:30一分鐘"),
        ("1:30八 ms", "1:30八 ms"),
        ("5:30五元", "5:30五元"),
        ("2:30五倍", "2:30五倍"),
        ("3:30一起去", "3:30一起去"),
        ("3:30三到五個人", "3:30三到五個人"),
        ("3:30一到就走", "3:30一到就走"),
        // 辨識器拆開的「四十二」照舊接回（後面就收尾或接時間字）。
        ("7.40二", "7.42"),
        ("7:40二到", "7:42到"),
        ("7:40二，", "7:42，"),
    ]

    /// T4 小數＋千不轉一半（以前「一點5,000元」）；萬照舊交給小數規則；小數點後面不念「兩」。
    static let t4DecimalThousandNeverHalfConverted: [(String, String)] = [
        ("一點五千元", "一點五千元"),
        ("這台冷氣一點五千瓦", "這台冷氣一點五千瓦"),
        ("三點五千米", "三點五千米"),
        ("大概一點五千塊左右", "大概一點五千塊左右"),
        ("一點五千萬", "一點五千萬"),
        ("差一點五千塊", "差一點五千塊"),
        ("一點五千 Hz", "一點五千 Hz"),
        ("還差一點五萬就達標", "還差15,000就達標"),
        ("這一點一萬塊不算什麼", "這一點10,000塊不算什麼"),
        ("一點五萬", "15,000"),
        ("三點兩千塊", "三點2,000塊"),
        ("下午三點兩千塊交給你", "下午三點2,000塊交給你"),
        ("三點千六塊", "三點1,600塊"),
        ("五千塊", "5,000塊"),
    ]

    /// T5 概數的百分比照講的留著（以前「10%幾」）；確定的百分比照轉。
    static let t5VaguePercentagesStayVague: [(String, String)] = [
        ("大概百分之十幾", "大概百分之十幾"),
        ("百分之二十幾的人", "百分之二十幾的人"),
        ("百分之十來", "百分之十來"),
        ("百分之五十多", "百分之五十多"),
        ("百分之十餘", "百分之十餘"),
        ("百分之十", "10%"),
        ("百分之五十的人", "50%的人"),
        ("百分之三點五", "3.5%"),
    ]

    /// FX-12 C1：序數的一～九留在第後，改口只替換鐘點。
    static let fx12C1OrdinalClockCorrection: [(String, String)] = [
        ("第一三點開會，不對，十點", "第一10:00開會"),
        ("第二三點開會，不對，十一點", "第二11:00開會"),
        ("第五四點出發，不對不對，十點", "第五10:00出發"),
        ("第九兩點到，我是說，十點", "第九10:00到"),
        ("第一三點開會，不對，四點", "第一4:00開會"),
        ("第二四點出發，不對，五點", "第二5:00出發"),
        ("第一三點半開會，不對，四點", "第一4:00開會"),
        ("第三五點集合，我是說六點", "第三六點集合"),
        ("第一九點集合，不對，十點", "第一十點集合"),
        ("第一三點，不對，四點開會", "第一4:00開會"),
    ]

    /// FX-12 C2：每週的十位小數數量整段替換，不留下假星期幾。
    static let fx12C2WeeklyDecimalQuantityCorrection: [(String, String)] = [
        ("每週三十點五小時，不對，四十點五小時", "每週四十點五小時"),
        ("每週三十點五個小時，不對，四十點五個小時", "每週四十點五個小時"),
        ("每週三十點五公里，不對，四十點五公里", "每週四十點五公里"),
        ("每週三十點五公斤，不對，四十點五公斤", "每週四十點五公斤"),
        ("每週三十點五分鐘，不對，四十點五分鐘", "每週四十點五分鐘"),
    ]

    /// FX-12 反面：星期鐘點、正常序數、名次／次數與普通鐘點逐字保留base讀法。
    static let fx12GuardReadings: [(String, String)] = [
        ("週三十點開會，不對，十一點", "週三11:00開會"),
        ("每週三十點開會，不對，十一點", "每週三11:00開會"),
        ("第一，三點開會，不對，四點", "第一，4:00開會"),
        ("第一是三點開會，不對，四點", "第一是4:00開會"),
        ("第十三點開會，不對，十四點", "第14:00開會"),
        ("第二十點集合，不對，二十一點", "第二十一點集合"),
        ("第一名三點領獎，不對，四點", "第一名四點領獎"),
        ("第一次三點開會，不對，四點", "第一次4:00開會"),
        ("禮拜五三點半，不對，四點", "禮拜五4:00"),
        ("三點開會，不對，四點", "4:00開會"),
        ("三點半，不對，四點", "4:00"),
    ]

    static let firstPasteCases = t1CorrectedClockReplacesTheWholeOldTime + t1NewMinutesOrNoOldMinutesUnchanged
        + t1UnreadableHourStaysAsSpoken + t2ArabicClockIsOneValue + fx12C1OrdinalClockCorrection + fx12C2WeeklyDecimalQuantityCorrection + fx12GuardReadings
    static let numberCases = t3ClockDigitsNeverJoinTheNextNumber + t4DecimalThousandNeverHalfConverted + t5VaguePercentagesStayVague
    /// GoldenExportTests 把這些放進 numbers.json。
    static let goldenInputs = (firstPasteCases + numberCases).map(\.0)

    private func firstPaste(_ raw: String) -> String {
        SentenceMood.finish(Normalizer().normalize(raw).cleaned)
    }

    private func checkFirstPaste(_ cases: [(String, String)]) {
        for (raw, expected) in cases { XCTAssertEqual(firstPaste(raw), expected, raw) }
    }

    private func checkNumbers(_ cases: [(String, String)]) {
        for (raw, expected) in cases { XCTAssertEqual(Normalizer.normalizeNumbers(raw), expected, raw) }
    }

    func testFX12GuardReadings() { checkFirstPaste(Self.fx12GuardReadings) }
    func testFX12C1OrdinalClockCorrection() { checkFirstPaste(Self.fx12C1OrdinalClockCorrection) }
    func testFX12C2WeeklyDecimalQuantityCorrection() { checkFirstPaste(Self.fx12C2WeeklyDecimalQuantityCorrection) }

    func testT1CorrectedClockReplacesTheWholeOldTime() { checkFirstPaste(Self.t1CorrectedClockReplacesTheWholeOldTime) }
    func testT1NewMinutesOrNoOldMinutesUnchanged() { checkFirstPaste(Self.t1NewMinutesOrNoOldMinutesUnchanged) }
    func testT1UnreadableHourStaysAsSpoken() { checkFirstPaste(Self.t1UnreadableHourStaysAsSpoken) }
    func testT2ArabicClockIsOneValue() { checkFirstPaste(Self.t2ArabicClockIsOneValue) }
    func testT3ClockDigitsNeverJoinTheNextNumber() { checkNumbers(Self.t3ClockDigitsNeverJoinTheNextNumber) }
    func testT4DecimalThousandNeverHalfConverted() { checkNumbers(Self.t4DecimalThousandNeverHalfConverted) }
    func testT5VaguePercentagesStayVague() { checkNumbers(Self.t5VaguePercentagesStayVague) }

    /// T4／T5 在整條第一次貼上也一樣（數字關前面的規則沒有先動到它們）。
    func testT4AndT5HoldOnTheFirstPaste() {
        for (raw, expected) in [("一點五千元", "一點五千元"), ("這台冷氣一點五千瓦", "這台冷氣一點五千瓦"), ("三點五千米", "三點五千米"),
                                ("百分之二十幾的人", "百分之二十幾的人"), ("大概百分之十幾", "大概百分之十幾"), ("百分之十來", "百分之十來")] {
            XCTAssertEqual(firstPaste(raw), expected, raw)
        }
    }

    /// T3 性質：normalizeNumbers 對整份數字標準答案語料冪等（閘門寬鬆那關會對已經正規化過的第一次貼上再跑一次）。
    /// 語料＝numbers.json 的全部輸入：NumberSpanTests＋這張票的案例＋fx-numbers／fx-six 語料檔。
    func testNormalizeNumbersIsIdempotentOverTheGoldenNumberCorpus() throws {
        let inputs = try Self.goldenNumberCorpus()
        XCTAssertGreaterThan(inputs.count, 9000, "語料讀不到（路徑壞了？）")
        var failures: [String] = []
        for input in inputs {
            let once = Normalizer.normalizeNumbers(input)
            let twice = Normalizer.normalizeNumbers(once)
            if twice != once { failures.append("「\(input)」→「\(once)」→「\(twice)」") }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 條再整理一次會變：\n" + failures.prefix(30).joined(separator: "\n"))
    }

    /// numbers.json 的輸入（GoldenExportTests 用同一份）。
    static func goldenNumberCorpus() throws -> [String] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func lines(_ file: String) throws -> [String] {
            try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        }
        // FX-8：CorrectionNumberLeftoverTests 的案例＋fx-eight 審查回報與 oracle 全部列＋新 fuzz 模板每 20 取 1
        //（benchmarks/fx-eight-golden-corpus.txt；fx-eight fuzz 前段就是 fx-six fuzz，只抽後段新加的星期／小數改口／小數＋百模板）。
        let inputs = NumberSpanTests.goldenInputs + (try lines("benchmarks/fx-numbers-golden-corpus.txt"))
            + goldenInputs + (try lines("benchmarks/fx-six-golden-corpus.txt"))
            + CorrectionNumberLeftoverTests.goldenInputs + (try lines("benchmarks/fx-eight-golden-corpus.txt"))
            // FX-11：fx-eleven 審查回報全部列＋新 fuzz 模板（小數×萬／億／千／百×單位×前後文）每 20 取 1（benchmarks/fx-eleven-golden-corpus.txt）。
            + (try lines("benchmarks/fx-eleven-golden-corpus.txt"))
        return Array(NSOrderedSet(array: inputs)) as! [String]
    }
}
