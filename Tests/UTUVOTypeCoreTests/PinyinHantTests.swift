import Foundation
import XCTest
@testable import UTUVOTypeCore

/// 繁體拼音：同一個 PinyinEngine／PinyinLexicon 開 pinyin-hant.dat（小麥注音詞庫轉拼音鍵）。
/// 另外直接讀 scripts/build-pinyin-hant-data.py 裡的注音→拼音對照表做健全性檢查，抓抄錯。
final class PinyinHantTests: XCTestCase {

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UTUVOTypeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    static let dataURL = repoRoot.appendingPathComponent("ios/Keyboard/Resources/pinyin-hant.dat")
    static let scriptURL = repoRoot.appendingPathComponent("scripts/build-pinyin-hant-data.py")

    static let sharedLexicon: PinyinLexicon? = PinyinLexicon(url: dataURL)

    private func lexicon() throws -> PinyinLexicon {
        try XCTUnwrap(Self.sharedLexicon, "找不到或無法解析 \(Self.dataURL.path)")
    }

    private func engine(typing keys: String) throws -> PinyinEngine {
        let e = PinyinEngine(lexicon: try lexicon())
        for ch in keys { XCTAssertTrue(e.type(ch), "「\(keys)」的 \(ch) 沒被接受") }
        return e
    }

    // MARK: - 轉換

    func testWholeBufferConversion() throws {
        let cases: [(String, [String])] = [
            ("nihao", ["你好"]),
            ("taibei", ["臺北", "台北"]),
            ("zhonghua", ["中華"]),
            ("women", ["我們"]),
            ("diannao", ["電腦"]),
            ("zhonghuaminguo", ["中華民國"]),
            ("jintiantianqihenhao", ["今天天氣很好"]),
        ]
        for (keys, expected) in cases {
            let e = try engine(typing: keys)
            XCTAssertTrue(expected.contains(e.preedit), "輸入 \(keys) 得到 \(e.preedit)，預期 \(expected)")
        }
    }

    func testXianCandidatesIncludeXianAndXiAn() throws {
        let e = try engine(typing: "xian")
        let texts = e.candidates.filter { $0.consumed == 4 }.map(\.text)
        XCTAssertTrue(texts.contains("先"), "\(texts.prefix(20))")
        XCTAssertTrue(texts.contains("現"), "\(texts.prefix(20))")
        XCTAssertTrue(texts.contains("西安"), "xian 也要能選 西安")
        let sep = try engine(typing: "xi'an")
        // 小麥注音的分數裡 西岸 略高於 西安，兩者都要是整段（含分隔號）的候選
        XCTAssertTrue(sep.candidates.contains(PinyinCandidate(text: "西安", consumed: 5)))
        XCTAssertTrue(["西安", "西岸"].contains(sep.preedit), sep.preedit)
    }

    func testAbbreviationAndUmlautWorkOnHantToo() throws {
        let nh = try engine(typing: "nh")
        XCTAssertTrue(nh.candidates.contains(PinyinCandidate(text: "你好", consumed: 2)))
        let zgr = try engine(typing: "zhongg")
        XCTAssertTrue(zgr.candidates.contains(PinyinCandidate(text: "中國", consumed: 6)))
        let lv = try engine(typing: "lvxing")
        XCTAssertEqual(lv.preedit, "旅行")
        let lve = try engine(typing: "lve")               // ㄌㄩㄝ 存成 lue，lve 走別名
        XCTAssertTrue(lve.candidates.contains { $0.text == "略" })
        let nue = try engine(typing: "nue")
        XCTAssertTrue(nue.candidates.contains { $0.text == "虐" })
    }

    // MARK: - 對照表健全性

    /// 從 build 腳本原始碼解析 `'ㄅㄚ': 'ba'` 形式的對照表（只看 BOPOMOFO_TO_PINYIN 區塊），
    /// 不另抄一份——測的就是出貨資料用的那張表。
    static func scriptTable() throws -> (table: [String: String], extras: Set<String>) {
        let source = try String(contentsOf: scriptURL, encoding: .utf8)
        guard let start = source.range(of: "BOPOMOFO_TO_PINYIN = {"),
              let end = source.range(of: "\n}\n", range: start.upperBound..<source.endIndex) else {
            throw XCTSkip("找不到對照表區塊")
        }
        let block = String(source[start.upperBound..<end.lowerBound])
        let pair = try NSRegularExpression(pattern: "'([\\x{3105}-\\x{3129}]+)':\\s*'([a-z]+)'")
        var table: [String: String] = [:]
        for m in pair.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
            let k = String(block[Range(m.range(at: 1), in: block)!])
            let v = String(block[Range(m.range(at: 2), in: block)!])
            XCTAssertNil(table[k], "對照表重複的鍵 \(k)")
            table[k] = v
        }
        guard let line = source.split(separator: "\n").first(where: { $0.hasPrefix("TAIWAN_ONLY_SYLLABLES = {") }) else {
            throw XCTSkip("找不到 TAIWAN_ONLY_SYLLABLES")
        }
        let word = try NSRegularExpression(pattern: "'([a-z]+)'")
        let l = String(line)
        let extras = Set(word.matches(in: l, range: NSRange(l.startIndex..., in: l)).map { String(l[Range($0.range(at: 1), in: l)!]) })
        return (table, extras)
    }

    /// 對照表裡每一個拼音都必須是合法音節：rime-pinyin-simp 的 415 個音節，或明列的臺灣讀音例外。
    func testEveryBopomofoSyllableMapsToValidPinyin() throws {
        let (table, extras) = try Self.scriptTable()
        XCTAssertGreaterThanOrEqual(table.count, 400, "對照表應涵蓋約 410 個基本音節")
        let simp = try XCTUnwrap(PinyinTests.sharedLexicon).syllables
        let valid = Set(simp.all).union(extras)
        for (bpmf, py) in table.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(valid.contains(py), "\(bpmf) → \(py) 不是合法拼音音節")
        }
        XCTAssertTrue(extras.isDisjoint(with: simp.all), "例外清單裡有 pinyin.dat 本來就有的音節：\(extras.intersection(simp.all))")
        // 除了 ㄝ（併入 ei）外一對一
        var seen: [String: String] = [:]
        for (bpmf, py) in table where bpmf != "ㄝ" {
            if let other = seen[py] { XCTFail("\(other) 與 \(bpmf) 都對到 \(py)") }
            seen[py] = bpmf
        }
        // 出貨的 pinyin-hant.dat 裡每個音節都來自這張表
        let hant = try lexicon().syllables
        let values = Set(table.values)
        for s in hant.all { XCTAssertTrue(values.contains(s), "pinyin-hant.dat 有表外音節 \(s)") }
    }

    /// 人工抽查：零聲母、ü 的兩種寫法、舌尖元音、兒化、ㄨㄥ／ㄩㄥ。
    func testSpotCheckMappings() throws {
        let (table, _) = try Self.scriptTable()
        let expected: [String: String] = [
            "ㄅㄚ": "ba", "ㄆㄛ": "po", "ㄇㄜ": "me", "ㄈㄥ": "feng", "ㄉㄧㄡ": "diu",
            "ㄊㄨㄟ": "tui", "ㄋㄩ": "nv", "ㄋㄩㄝ": "nue", "ㄌㄩ": "lv", "ㄌㄩㄝ": "lue",
            "ㄍㄨㄥ": "gong", "ㄎㄨㄣ": "kun", "ㄏㄨㄛ": "huo", "ㄐㄩ": "ju", "ㄐㄩㄝ": "jue",
            "ㄑㄩㄢ": "quan", "ㄒㄩㄣ": "xun", "ㄒㄩㄥ": "xiong", "ㄓ": "zhi", "ㄔ": "chi",
            "ㄕ": "shi", "ㄖ": "ri", "ㄗ": "zi", "ㄘ": "ci", "ㄙ": "si",
            "ㄦ": "er", "ㄧ": "yi", "ㄨ": "wu", "ㄩ": "yu", "ㄧㄡ": "you",
            "ㄨㄟ": "wei", "ㄨㄣ": "wen", "ㄨㄥ": "weng", "ㄩㄝ": "yue", "ㄩㄢ": "yuan",
            "ㄩㄣ": "yun", "ㄩㄥ": "yong", "ㄧㄣ": "yin", "ㄧㄥ": "ying", "ㄓㄨㄤ": "zhuang",
        ]
        for (bpmf, py) in expected {
            XCTAssertEqual(table[bpmf], py, bpmf)
        }
    }

    /// 同一批對照從資料面再驗一次：字真的出現在對應拼音下。
    func testSpotCheckCharactersUnderMappedPinyin() throws {
        let lex = try lexicon()
        let cases: [(String, String)] = [
            ("zhi", "知"), ("chi", "吃"), ("shi", "是"), ("ri", "日"), ("zi", "字"), ("ci", "次"), ("si", "四"),
            ("er", "二"), ("yi", "一"), ("wu", "五"), ("yu", "魚"), ("you", "有"), ("wei", "為"), ("yue", "月"),
            ("yuan", "元"), ("yun", "雲"), ("yong", "用"), ("weng", "翁"), ("ju", "居"), ("que", "卻"),
            ("xuan", "選"), ("jun", "軍"), ("nv", "女"), ("lv", "綠"), ("lue", "略"), ("nue", "虐"),
            ("xiong", "兄"), ("zhong", "中"), ("dong", "東"), ("ya", "牙"),
        ]
        for (py, ch) in cases {
            XCTAssertTrue(lex.lookup(syllables: [py]).contains { $0.text == ch }, "\(ch) 不在 \(py) 下")
        }
    }

    // MARK: - 效能

    func testLongInputStaysFast() throws {
        // 詞庫最長 9 音節的詞，Viterbi 每段延伸更深；確認仍在預算內
        let keys = "womenjintianzaitaibeishidediannaogongsikaihui"
        let lex = try lexicon()
        let e = PinyinEngine(lexicon: lex)
        var worst = 0.0
        for ch in keys {
            let t = Date()
            e.type(ch)
            _ = e.preedit
            _ = e.candidates
            worst = max(worst, Date().timeIntervalSince(t))
        }
        XCTAssertEqual(e.preedit, "我們今天在台北市的電腦公司開會")
        XCTAssertLessThan(worst, 0.050, "最慢一鍵 \(worst * 1000) ms")
    }
}
