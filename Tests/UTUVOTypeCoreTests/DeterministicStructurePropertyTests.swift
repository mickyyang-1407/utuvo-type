import Foundation
import XCTest
@testable import UTUVOTypeCore

/// 條列與分段的性質測試（2026-10-22 W2-6 修正）：兩份審查的探針＋44 句真人錄音辨識結果
/// （`android/core/src/test/resources/structure-probes.json`，Kotlin 版 StructurePropertyTest 讀同一份）。
/// - 條列／分段只能加編號、換行、標點，不能吃掉內容字（中文、英文字母、數字）。
/// - 整理兩次跟整理一次一樣。
final class DeterministicStructurePropertyTests: XCTestCase {
    let n = Normalizer()

    static let probesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("android/core/src/test/resources/structure-probes.json")

    static func probes() throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(contentsOf: probesURL))
    }

    func testListAndParagraphStagesKeepEveryContentCharacter() throws {
        let probes = try Self.probes()
        XCTAssertGreaterThanOrEqual(probes.count, 250, "探針檔讀不到或被截短")
        var failures: [String] = []
        for input in probes {
            let before = n.normalize(input, stoppingBefore: "list").cleaned
            let after = n.normalize(input).cleaned
            if let problem = StructureInvariant.firstDroppedContent(before: before, after: after) {
                failures.append("「\(input)」\n  → 「\(after)」\n  \(problem)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 條吃字：\n" + failures.prefix(20).joined(separator: "\n"))
    }

    /// 第三輪政策（2026-10-22）：不符合條列規則的序數串整句原樣。條列這一關不能只切行不編號——
    /// 編號清單模式下，條列後面的文字裡不能多出「第N」開頭的行（第二輪以前「我們要的是第二版不是第三版」被切成三行）。
    func testListStageNeverSplitsAnOrdinalWithoutNumberingIt() throws {
        var failures: [String] = []
        for input in try Self.probes() {
            let before = n.normalize(input, stoppingBefore: "list").cleaned
            let listed = n.normalize(input, stoppingBefore: "paragraph").cleaned
            if StructureInvariant.ordinalLineStarts(listed) > StructureInvariant.ordinalLineStarts(before) {
                failures.append("「\(input)」\n  → 「\(listed)」")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 條只切行沒編號：\n" + failures.prefix(20).joined(separator: "\n"))
    }

    func testNormalizeIsIdempotentOnAllProbes() throws {
        var failures: [String] = []
        for input in try Self.probes() {
            let once = n.normalize(input).cleaned
            let twice = n.normalize(once).cleaned
            if twice != once { failures.append("「\(input)」\n  一次 「\(once)」\n  兩次 「\(twice)」") }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) 條整理兩次結果不同：\n" + failures.prefix(20).joined(separator: "\n"))
    }

    /// 檢查器本身不能永遠綠燈：修正前的吃字輸出要被抓到，正常的編號／拿掉「還有」要放行。
    func testInvariantCheckerIsNotHollow() {
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "我要買三樣東西，豬肉、雞肉、和牛", after: "我要買三樣東西：\n1. 豬肉\n2. 雞肉\n3. 牛"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "這次要拍兩個，定點、跟拍", after: "這次要拍兩個：\n1. 定點\n2. 拍"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "我想到兩個，戰爭、和平", after: "我想到兩個：\n1. 戰爭\n2. 平"))
        // 第三輪（2026-10-22）：「N. 」只能代替符合條列規則的「第N」。修正前這幾條都算沒吃字（「1. 」被當成「第一」）。
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "第一軌是 kick，第二是 snare，第三是 hihat", after: "1. 軌是 kick\n2. snare\n3. hihat"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "我們錄了三遍，第一遍太快，第二是太慢，第三剛好", after: "我們錄了三遍：\n1. 遍太快\n2. 太慢\n3. 剛好"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "第一小提琴太大聲，第二中提琴太小聲，第三大提琴剛好", after: "1. 小提琴太大聲\n2. 中提琴太小聲\n3. 大提琴剛好"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "樂團裡第一吉他是阿明，第二貝斯是小華，第三鍵盤是阿強", after: "樂團裡：\n1. 吉他是阿明\n2. 貝斯是小華\n3. 鍵盤是阿強"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "第一買牛奶，第二買麵包，第三寫報告", after: "1. 買牛奶\n2. 買麵包\n3. 寫報告"), "沒有清單引言")
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "今天有兩件事，第一買牛奶第二回email第三寫報告", after: "今天有兩件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"), "數量對不上")
        // 第四輪（2026-10-22）政策 (A)：「第二」緊接在「奶」後面不是子句開頭——沒有標點的連續序數串不能編號（第三輪這條是 Nil）。
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "今天有三件事第一買牛奶第二回email第三寫報告", after: "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "今天有三件事，第一買牛奶，第二回email，第三寫報告", after: "今天有三件事：\n1. 買牛奶\n2. 回email\n3. 寫報告"))
        // 第四輪：排名／口號（第N 收在子句結尾）與「第N＋名詞」不能編號。修正前第一條算沒吃字（「速度」前面是「，」就放行）。
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "安全第一，速度第二，大家小心開車", after: "安全：\n1. 速度\n2. 大家小心開車"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "他拿了第一，我拿了第二，大家都很開心", after: "他拿了：\n1. 我拿了\n2. 大家都很開心"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "今天有兩件事，第一小提琴重錄，第二小提琴補錄", after: "今天有兩件事：\n1. 小提琴重錄\n2. 小提琴補錄"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "今天錄三樣，第一小提琴，第二中提琴，第三大提琴", after: "今天錄三樣：\n1. 小提琴\n2. 中提琴\n3. 大提琴"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "以下第一小提琴重錄第二小提琴補錄", after: "以下：\n1. 小提琴重錄\n2. 小提琴補錄"))
        XCTAssertNotNil(StructureInvariant.firstDroppedContent(before: "這週有兩件事，第一排錄音，第二排混音", after: "這週有兩件事：\n1. 排錄音\n2. 排混音"), "排＝量詞 (C)")
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "以下兩點：第一確認檔案，第二上傳雲端", after: "以下兩點：\n1. 確認檔案\n2. 上傳雲端"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "我說兩件事。第一是買菜，第二是煮飯", after: "我說兩件事。\n1. 買菜\n2. 煮飯"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "第一，安全；第二，速度", after: "1. 安全\n2. 速度"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "今天的工作清單是第一更新Pro Tools,第二匯出Stems,第三寫交付說明", after: "今天的工作清單是：\n1. 更新Pro Tools\n2. 匯出Stems\n3. 寫交付說明"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "第一個是麥克風，第二點是耳機", after: "1. 麥克風\n2. 耳機"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "第一是不是要先開會，第二是誰負責", after: "1. 是不是要先開會\n2. 誰負責"))
        XCTAssertEqual(StructureInvariant.ordinalLineStarts("我們要的是\n第二版不是\n第三版"), 2)
        XCTAssertEqual(StructureInvariant.ordinalLineStarts("第一是A，第三是B"), 1)
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭",
                                                            after: "幫我準備四樣東西：\n1. 播放器\n2. 耳機\n3. 線材\n4. 轉接頭"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "第一是買菜；第二是煮飯", after: "1. 買菜\n2. 煮飯"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "預算很緊，然後另外要再找人", after: "預算很緊。\n\n另外要再找人"))
        XCTAssertNil(StructureInvariant.firstDroppedContent(before: "1. 買牛奶\n2. 回信", after: "1. 買牛奶\n2. 回信"))
    }
}

/// 條列／分段前後的內容字比對：前一關的內容字要依序出現在結果裡。
/// 例外（本來就該拿掉的）：「第N是／第N個是／第N點是…」的「是／個是／點是…」（「是否／是不是」不算）、列舉最後一項開頭的「還有／以及」、
/// 新段開頭轉折詞前面的「然後／那」；行首「N. 」當成「第N」比——但只在那一項符合條列規則的時候（見 `unqualifiedNumbering`）。
enum StructureInvariant {
    static func firstDroppedContent(before: String, after: String) -> String? {
        if let problem = unqualifiedNumbering(before: before, after: after) { return problem }
        var b = numberedMarkersAsOrdinals(before)
        b = replace(b, "(第[一二三四五六七八九十]{1,3})[ \\t]*[個點項步件就]?是(?!否|不是)", "$1")
        b = replace(b, "、[ \\t]*(?:還有|以及)", "、")
        let openers = (Normalizer.paragraphOpeners + Normalizer.paragraphClosers + Normalizer.paragraphWeakOpeners)
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        b = replace(b, "(^|[，,。！？!?；;\\s])(?:然後|那)(?=\(openers))", "$1")
        let want = content(b), have = content(numberedMarkersAsOrdinals(after))
        var j = 0
        for (i, ch) in want.enumerated() {
            while j < have.count, have[j] != ch { j += 1 }
            if j == have.count {
                return "第 \(i) 個內容字「\(ch)」不見了（前後文「\(String(want[max(0, i - 6)..<min(want.count, i + 6)]))」）"
            }
            j += 1
        }
        return nil
    }

    static func content(_ s: String) -> [Character] { s.filter { $0.isLetter || $0.isNumber } }

    // MARK: 「N. 」只能代替符合條列規則的「第N」（2026-10-22 第三輪；修正前任何「第N」都能換成「N. 」，「第一軌→1. 軌」照樣綠燈）

    /// 條列政策照規格另外寫一份（不呼叫 Normalizer）。量詞用政策列的字。
    static let measureWords = ["小節", "聲道", "回合"] + "軌台遍支個次首張件項點步章節段位名天週年輪場集拍層樓號種款顆則筆趟口套組隻條把本部版的頁列排關".map(String.init)
    /// 第四輪（2026-10-22）政策 (B) 的動作動詞：票面列的字＋「重開／重新」（重開機、重新整理）＋同一批字的簡體。
    static let actionVerbs = ["買", "回", "寫", "交", "做", "改", "加", "刪", "寄", "送", "帶", "排", "繳", "洗", "煮", "倒", "拿", "找", "問",
                              "練", "讀", "修", "開", "關", "去", "準備", "更新", "匯出", "匯入", "確認", "檢查", "整理", "收", "錄", "補錄",
                              "重錄", "重做", "上傳", "下載", "安裝", "測試", "聯絡", "通知", "預約", "處理", "安排", "提醒", "規劃", "設定",
                              "備份", "重開", "重新",
                              "买", "写", "删", "带", "缴", "问", "练", "读", "开", "关", "录", "准备", "汇出", "汇入", "确认", "检查", "补录",
                              "重录", "重开", "上传", "下载", "安装", "测试", "联络", "预约", "处理", "规划", "备份"]
    static let countIntro = "(?<![第0-9一二三四五六七八九十兩百])(?:([兩二三四五六七八九十]|10|[2-9])(?:件事情|件事|樣東西|樣|項|個步驟|個重點)|([兩二三四五六七八九十])點)"
    static let counts = ["兩": 2, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "10": 10,
                         "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9]
    static let ordinalCue = "第[一二三四五六七八九十]{1,3}"

    static func matches(_ pattern: String, in s: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern))?.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)) ?? []
    }

    /// 結果裡每一行「K. 內容」：內容在整理前的文字裡，前面要是本來就有的「K. 」、不接在「第N」後面的分隔（頓號列舉、引言的冒號，
    /// 可再接「還有／以及」），或一個「第K」——它要過第四輪政策（2026-10-22）三關：
    /// (A) 在子句開頭：前面是開頭、分隔（，,、：:；;。！？空白、換行）或清單引言本身（清單是／以下／如下／N件事／N樣／N點…）；
    /// (C) 後面不接量詞；
    /// (B) 後面接分隔、空白、「是／個是／點是／項是／步是／件是／就是」（或「是否／是不是」），或直接接內容而且內容用政策的動作動詞開頭、
    ///     引言講了跟這句「第N」個數一樣的數量（或以下／如下／清單）。都不是＝把不該編號的「第K」換成了「K. 」。
    static func unqualifiedNumbering(before: String, after: String) -> String? {
        let ns = before as NSString
        for line in after.components(separatedBy: "\n") {
            guard let m = line.range(of: "^[ \\t]*[0-9]{1,2}\\. ", options: .regularExpression),
                  let k = Int(String(line[m].filter(\.isNumber))) else { continue }
            let key = Array(line[m.upperBound...].filter { $0.isLetter || $0.isNumber }.prefix(2))
            guard let first = key.first else { continue }
            var pattern = NSRegularExpression.escapedPattern(for: String(first))
            if key.count > 1 { pattern += "[^\\p{L}\\p{N}]*" + NSRegularExpression.escapedPattern(for: String(key[1])) }
            let allowed = matches(pattern, in: before).contains { hit in
                numberingAllowed(head: ns.substring(to: hit.range.location), item: ns.substring(from: hit.range.location), value: k)
            }
            if !allowed { return "「\(line)」：整理前這一項前面不是符合條列規則的「第\(chinese(k))」或分隔，不能換成編號" }
        }
        return nil
    }

    static func numberingAllowed(head rawHead: String, item: String, value k: Int) -> Bool {
        var head = rawHead
        while let last = head.last, last == " " || last == "\t" { head.removeLast() }
        let spaced = head.count < rawHead.count
        if head.range(of: "(?:^|\\n)[ \\t]*\(k)\\.$", options: .regularExpression) != nil { return true }
        let ordinal = "第" + chinese(k)
        // 「第N」＋分隔或「是」類＝明確的序號 (B)：要是第 K，而且在子句開頭 (A)。
        if let hit = matches("(第[一二三四五六七八九十]{1,3})[ \\t]*(?:[、，,：:]|[個點項步件就]?是)$", in: head).first {
            let ns = head as NSString
            return ns.substring(with: hit.range(at: 1)) == ordinal && atClauseStart(ns.substring(to: hit.range.location))
        }
        if head.range(of: "[、，,：:](?:[ \\t]*(?:還有|以及))?$", options: .regularExpression) != nil { return true }
        guard head.hasSuffix(ordinal), atClauseStart(String(head.dropLast(ordinal.count))) else { return false }  // (A)
        if measureWords.contains(where: { item.hasPrefix($0) }) { return false }  // (C)
        if spaced || item.hasPrefix("是否") || item.hasPrefix("是不是") { return true }
        // (B)：直接接內容＝這一項要用政策的動作動詞開頭。
        guard actionVerbs.contains(where: { item.hasPrefix($0) }) else { return false }
        // (B)：引言＝這句第一個「第N」前面，那裡沒有字就看前一句；最後一個子句講的數量要等於這句「第N」的個數。
        let parts = head.split(omittingEmptySubsequences: false, whereSeparator: { "。！？!?\n".contains($0) }).map(String.init)
        let sentence = (parts.last ?? "") + String(item.prefix(while: { !"。！？!?\n".contains($0) }))
        let cues = matches(ordinalCue, in: sentence).count
        guard let firstCue = sentence.range(of: ordinalCue, options: .regularExpression) else { return false }
        var intro = String(sentence[..<firstCue.lowerBound])
        if !intro.contains(where: { $0.isLetter || $0.isNumber }) { intro = parts.dropLast().last ?? "" }
        intro = intro.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n，,、：:；;。！？!?"))
        if let cut = intro.lastIndex(where: { "，,、；;：:".contains($0) }) { intro = String(intro[intro.index(after: cut)...]) }
        if let hit = matches(countIntro, in: intro).last {
            let group = hit.range(at: 1).location != NSNotFound ? hit.range(at: 1) : hit.range(at: 2)
            return counts[(intro as NSString).substring(with: group)] == cues
        }
        return ["以下", "如下", "清單"].contains { intro.contains($0) }
    }

    /// (A) 「第N」前面（`pre`）是子句開頭：開頭、分隔、句尾（可接引號括號）或清單引言本身。
    static func atClauseStart(_ pre: String) -> Bool {
        guard let last = pre.last else { return true }
        if " \t\n\r，,、：:；;。！？!?".contains(last) || last == "\r\n" { return true }
        if pre.range(of: "[。！？!?][」』”\"）)]+$", options: .regularExpression) != nil { return true }
        return pre.range(of: "(?:清單是|清單|以下|如下|" + countIntro + ")$", options: .regularExpression) != nil
    }

    /// 「第N」開頭的行數（條列這一關不能只切行不編號）。
    static func ordinalLineStarts(_ s: String) -> Int {
        s.components(separatedBy: "\n").filter { $0.range(of: "^[ \\t]*" + ordinalCue, options: .regularExpression) != nil }.count
    }

    static func numberedMarkersAsOrdinals(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(?m)^[ \\t]*([0-9]{1,2})\\. ") else { return s }
        let ns = s as NSString
        var out = s
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let value = Int(ns.substring(with: m.range(at: 1))) ?? 0
            out = (out as NSString).replacingCharacters(in: m.range, with: "第" + chinese(value))
        }
        return out
    }

    static func chinese(_ n: Int) -> String {
        let d = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if n < 10 { return d[n] }
        let tens = n / 10, ones = n % 10
        return (tens == 1 ? "" : d[tens]) + "十" + (ones == 0 ? "" : d[ones])
    }

    static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
