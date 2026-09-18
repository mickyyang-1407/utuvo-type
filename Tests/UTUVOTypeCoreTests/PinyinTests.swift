import Foundation
import XCTest
@testable import UTUVOTypeCore

/// 簡體拼音引擎：音節表與切分、詞庫（mmap 二分搜尋＋音節區間查詢）、整句轉換、候選、
/// 縮寫／未打完音節、效能與記憶體。
/// 詞庫走 repo 裡真正出貨的 ios/Keyboard/Resources/pinyin.dat（以 #filePath 定位），
/// 不用合成的小詞庫——要驗的是鍵盤實際會拿到的資料。
final class PinyinTests: XCTestCase {

    static let dataURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UTUVOTypeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("ios/Keyboard/Resources/pinyin.dat")

    static let sharedLexicon: PinyinLexicon? = PinyinLexicon(url: dataURL)

    private func lexicon() throws -> PinyinLexicon {
        try XCTUnwrap(Self.sharedLexicon, "找不到或無法解析 \(Self.dataURL.path)")
    }

    private func makeEngine() throws -> PinyinEngine {
        PinyinEngine(lexicon: try lexicon())
    }

    /// 依序打字，回傳每個字元是否被接受。
    @discardableResult
    private func typeAll(_ engine: PinyinEngine, _ keys: String) -> [Bool] {
        keys.map { engine.type($0) }
    }

    private func engine(typing keys: String) throws -> PinyinEngine {
        let e = try makeEngine()
        let accepted = typeAll(e, keys)
        XCTAssertTrue(accepted.allSatisfy { $0 }, "「\(keys)」有字元沒被接受：\(accepted)")
        return e
    }

    // MARK: - 音節表

    func testSyllableTableComesFromData() throws {
        let syl = try lexicon().syllables
        XCTAssertEqual(syl.count, 415, "rime-pinyin-simp 的音節數")
        for s in ["a", "ni", "hao", "zhuang", "lv", "nv", "lue", "nue", "er", "ng"] {
            XCTAssertTrue(syl.isValid(s), "缺音節 \(s)")
        }
        XCTAssertTrue(syl.isValid("lve"), "lve 是 lue 的別名")
        XCTAssertEqual(syl.id("lve"), syl.id("lue"))
        for s in ["iu", "v", "zhv", "bong", "xa", ""] {
            XCTAssertFalse(syl.isValid(s), "\(s) 不該是音節")
        }
        XCTAssertFalse(syl.canStartSyllable("i"))
        XCTAssertFalse(syl.canStartSyllable("u"))
        XCTAssertFalse(syl.canStartSyllable("v"))
        XCTAssertTrue(syl.canStartSyllable("x"))
        // 前綴區間是連續的：zh 開頭的每個音節都在區間內、區間外沒有
        let zh = try XCTUnwrap(syl.range(prefix: "zh"))
        for (i, s) in syl.all.enumerated() {
            XCTAssertEqual(zh.contains(UInt16(i)), s.hasPrefix("zh"), s)
        }
    }

    // MARK: - 切分

    func testSegmentationsBySyllableTable() throws {
        let syl = try lexicon().syllables
        XCTAssertEqual(syl.segmentations("nihao").first, ["ni", "hao"])
        let xian = syl.segmentations("xian")
        XCTAssertEqual(xian.first, ["xian"], "最長匹配優先")
        XCTAssertTrue(xian.contains(["xi", "an"]), "也要列出 xi an 這種切法")
        XCTAssertEqual(syl.segmentations("xi'an").first, ["xi", "an"], "' 是強制分界")
        XCTAssertFalse(syl.segmentations("xi'an").contains(["xian"]))
        XCTAssertEqual(syl.segmentations("zhongguoren").first, ["zhong", "guo", "ren"])
        XCTAssertEqual(syl.segmentations("lvxing").first, ["lv", "xing"], "ü 寫成 v")
        // 不合法的輸入
        XCTAssertEqual(syl.segmentations("nihao1"), [], "數字")
        XCTAssertEqual(syl.segmentations("NIHAO"), [], "大寫")
        XCTAssertEqual(syl.segmentations("ni hao"), [], "空白")
        XCTAssertEqual(syl.segmentations("iou"), [], "i 開頭切不出來")
        XCTAssertEqual(syl.segmentations("zhg"), [], "縮寫不是完整音節")
        XCTAssertEqual(syl.segmentations(""), [])
    }

    func testBestSegmentationIsWeightedByPhraseScores() throws {
        let e = try makeEngine()
        XCTAssertEqual(e.segment("nihao"), ["ni", "hao"])
        XCTAssertEqual(e.segment("xian"), ["xian"], "先／现 比 西安 常用")
        XCTAssertEqual(e.segment("xi'an"), ["xi", "an"])
        XCTAssertEqual(e.segment("zhongguoren"), ["zhong", "guo", "ren"])
        XCTAssertEqual(e.segment("lvxing"), ["lv", "xing"])
        XCTAssertEqual(e.segment("fangan"), ["fang", "an"], "方案（fang an）勝過 fan gan")
        XCTAssertEqual(e.segment("ni-hao"), [])
        XCTAssertTrue(e.isEmpty, "segment 不動引擎狀態")
    }

    // MARK: - 輸入規則

    func testTypeRejectsInvalidInput() throws {
        let e = try makeEngine()
        for ch: Character in ["1", "A", " ", "ü", "-", "，", "'"] {
            XCTAssertFalse(e.type(ch), "\(ch) 不該被接受（空緩衝區）")
        }
        XCTAssertFalse(e.type("i"), "沒有音節以 i 開頭")
        XCTAssertFalse(e.type("u"))
        XCTAssertFalse(e.type("v"))
        XCTAssertTrue(e.isEmpty)
        XCTAssertTrue(e.type("x"))
        XCTAssertTrue(e.type("i"), "音節中間的 i 可以")
        XCTAssertTrue(e.type("'"))
        XCTAssertFalse(e.type("'"), "連打兩個分隔號")
        XCTAssertFalse(e.type("u"), "分隔號之後是新音節開頭")
        XCTAssertTrue(e.type("a"))
        XCTAssertEqual(e.composing, "xi'a")

        let full = try makeEngine()
        for _ in 0..<PinyinEngine.maximumBufferLength { XCTAssertTrue(full.type("a")) }
        XCTAssertFalse(full.type("a"), "緩衝區上限")
    }

    func testBackspaceRemovesOneCharacter() throws {
        let e = try engine(typing: "xi'an")
        XCTAssertTrue(e.backspace())
        XCTAssertEqual(e.composing, "xi'a")
        XCTAssertTrue(e.backspace())
        XCTAssertEqual(e.composing, "xi'")
        XCTAssertTrue(e.backspace(), "分隔號也是一個字元")
        XCTAssertEqual(e.composing, "xi")
        XCTAssertEqual(e.preedit, "系")
        XCTAssertTrue(e.backspace())
        XCTAssertTrue(e.backspace())
        XCTAssertTrue(e.isEmpty)
        XCTAssertFalse(e.backspace(), "空的回 false")
    }

    // MARK: - 詞庫

    func testLexiconLookupIsBestFirst() throws {
        let lex = try lexicon()
        XCTAssertEqual(lex.maximumPhraseLength, 4)
        XCTAssertGreaterThan(lex.entryCount, 60_000)
        XCTAssertEqual(lex.lookup(syllables: ["ni", "hao"]).first?.text, "你好")
        let shi = lex.lookup(syllables: ["shi"])
        XCTAssertEqual(shi.first?.text, "是")
        XCTAssertTrue(zip(shi, shi.dropFirst()).allSatisfy { $0.score >= $1.score }, "分數要由高到低")
        XCTAssertTrue(lex.lookup(syllables: ["bei", "jing", "da", "xue"]).map(\.text).contains("北京大学"))
        XCTAssertTrue(lex.lookup(syllables: ["zhong", "guo", "ren"]).map(\.text).contains("中国人"))
        XCTAssertEqual(lex.lookup(syllables: ["lv", "xing"]).map(\.text).contains("旅行"), true)
        XCTAssertTrue(lex.lookup(syllables: ["xa"]).isEmpty, "不存在的音節查無結果")
        XCTAssertTrue(lex.lookup(syllables: []).isEmpty)
        // 前綴查詢：n* h*
        let nh = lex.lookup(prefixes: ["n", "h"])
        XCTAssertTrue(nh.map(\.text).contains("你好"))
        XCTAssertTrue(zip(nh, nh.dropFirst()).allSatisfy { $0.score >= $1.score }, "跨鍵合併後仍依分數排序")
        XCTAssertEqual(lex.lookup(prefixes: ["n", "h"], limit: 5).map(\.text), Array(nh.prefix(5).map(\.text)),
                       "limit 只截斷、不改變排序")
    }

    // MARK: - 轉換

    func testWholeBufferConversion() throws {
        let cases: [(String, String)] = [
            ("nihao", "你好"),
            ("zhongguo", "中国"),
            ("women", "我们"),
            ("xianzai", "现在"),
            ("zhongguoren", "中国人"),                       // 3 音節詞
            ("beijingdaxue", "北京大学"),                    // 4 音節詞
            ("woxiangqubeijingdaxue", "我想去北京大学"),       // 7 音節、多段
            ("zhonghuarenmingongheguo", "中华人民共和国"),     // 7 音節、多段
            ("xi'an", "西安"),
        ]
        for (keys, expected) in cases {
            let e = try engine(typing: keys)
            XCTAssertEqual(e.preedit, expected, "輸入 \(keys)")
        }
    }

    func testLvAsVConvertsAndLveAlias() throws {
        let e = try engine(typing: "lvxing")
        XCTAssertEqual(e.bestSegmentation, ["lv", "xing"])
        XCTAssertTrue(e.candidates.contains(PinyinCandidate(text: "旅行", consumed: 6)))
        XCTAssertTrue(e.candidates.contains(PinyinCandidate(text: "女", consumed: 2)) == false, "lv 不是 nv")
        let lve = try engine(typing: "lve")
        XCTAssertEqual(lve.preedit, "略")
    }

    func testUnconvertibleTailFallsBackToLetters() throws {
        let e = try engine(typing: "nihaoi")
        XCTAssertEqual(e.preedit, "你好i")
        XCTAssertEqual(e.commitAll(), "你好i", "不吞使用者打的字")
        XCTAssertTrue(e.isEmpty)
    }

    // MARK: - 候選

    func testXianOffersXianAndXiAn() throws {
        let e = try engine(typing: "xian")
        let c = e.candidates
        XCTAssertEqual(c.first, PinyinCandidate(text: "先", consumed: 4))
        XCTAssertTrue(c.contains(PinyinCandidate(text: "现", consumed: 4)))
        XCTAssertTrue(c.contains(PinyinCandidate(text: "西安", consumed: 4)), "xian 也要能選 西安")
        XCTAssertTrue(c.contains(PinyinCandidate(text: "西", consumed: 2)), "也能只選 xi")

        let sep = try engine(typing: "xi'an")
        XCTAssertEqual(sep.candidates.first, PinyinCandidate(text: "西安", consumed: 5), "consumed 含分隔號")
        XCTAssertFalse(sep.candidates.contains { $0.text == "先" }, "有分隔號就不能是 xian")
    }

    func testCandidatesAreLongestFirstAndIncludeSingles() throws {
        let e = try engine(typing: "zhongguoren")
        let c = e.candidates
        XCTAssertEqual(c.first, PinyinCandidate(text: "中国人", consumed: 11))
        let consumed = c.map(\.consumed)
        XCTAssertEqual(consumed, consumed.sorted(by: >), "覆蓋長的在前")
        XCTAssertTrue(c.contains(PinyinCandidate(text: "中国", consumed: 8)))
        XCTAssertTrue(c.contains(PinyinCandidate(text: "中", consumed: 5)))
        XCTAssertLessThanOrEqual(c.count, PinyinEngine.candidateLimit)
        XCTAssertEqual(Set(c.map { "\($0.consumed)|\($0.text)" }).count, c.count, "不重複")
    }

    func testFullPinyinDoesNotOfferStrayAbbreviations() throws {
        // nihao：只吃掉 n 的候選會留下無法切分的 ihao；women：w 讀得出完整音節 wo，不當縮寫
        for keys in ["nihao", "women", "zhongguo"] {
            let e = try engine(typing: keys)
            XCTAssertFalse(e.candidates.contains { $0.consumed == 1 }, "\(keys) 出現只吃一個字母的候選")
        }
    }

    // MARK: - 縮寫與未打完的音節

    func testInitialsAbbreviation() throws {
        let nh = try engine(typing: "nh")
        XCTAssertEqual(nh.preedit, "你好")
        XCTAssertTrue(nh.candidates.contains(PinyinCandidate(text: "你好", consumed: 2)))
        XCTAssertEqual(nh.bestSegmentation, ["n", "h"])

        let zg = try engine(typing: "zg")
        XCTAssertTrue(zg.candidates.contains(PinyinCandidate(text: "中国", consumed: 2)))

        let zgr = try engine(typing: "zgr")
        XCTAssertEqual(zgr.preedit, "中国人")

        let bjdx = try engine(typing: "bjdx")
        XCTAssertEqual(bjdx.candidates.first, PinyinCandidate(text: "北京大学", consumed: 4))

        let mixed = try engine(typing: "zhongg")        // 全拼＋縮寫混打
        XCTAssertEqual(mixed.preedit, "中国")
    }

    func testIncompleteLastSyllable() throws {
        let nih = try engine(typing: "nih")
        XCTAssertEqual(nih.preedit, "你好")
        XCTAssertTrue(nih.candidates.contains(PinyinCandidate(text: "你好", consumed: 3)))
        XCTAssertEqual(nih.bestSegmentation, ["ni", "h"])

        let wom = try engine(typing: "wom")
        XCTAssertEqual(wom.preedit, "我们")
    }

    /// 已記錄的限制：未打完的音節只在最後一段有效；中間的 `zhon`（少了 g）不會被當成 zhong。
    func testIncompleteMiddleSyllableIsNotSupported() throws {
        let e = try engine(typing: "zhonguo")
        XCTAssertNotEqual(e.preedit, "中国")
        XCTAssertFalse(e.candidates.contains { $0.text == "中国" })
    }

    // MARK: - 選字與送出

    func testSelectConsumesLettersFromTheFront() throws {
        let e = try engine(typing: "nihao")
        let ni = try XCTUnwrap(e.candidates.first { $0.text == "你" })
        XCTAssertEqual(ni.consumed, 2)
        XCTAssertEqual(e.select(ni), "你")
        XCTAssertEqual(e.composing, "hao")
        XCTAssertEqual(e.candidates.first?.text, "好")
        XCTAssertEqual(e.select(PinyinCandidate(text: "過期", consumed: 9)), "", "過期候選不動緩衝區")
        XCTAssertEqual(e.composing, "hao")
        XCTAssertEqual(e.select(PinyinCandidate(text: "好", consumed: 3)), "好")
        XCTAssertTrue(e.isEmpty)

        // 分隔號跟著前一段一起被吃掉
        let sep = try engine(typing: "xi'an")
        let xi = try XCTUnwrap(sep.candidates.first { $0.text == "西" })
        XCTAssertEqual(xi.consumed, 3)
        XCTAssertEqual(sep.select(xi), "西")
        XCTAssertEqual(sep.composing, "an")
        XCTAssertTrue(sep.candidates.contains(PinyinCandidate(text: "安", consumed: 2)))
    }

    func testCommitAllReturnsConversionAndResets() throws {
        let e = try engine(typing: "nihao")
        XCTAssertEqual(e.commitAll(), "你好")
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.composing, "")
        XCTAssertEqual(e.preedit, "")
        XCTAssertEqual(e.candidates, [])
        XCTAssertEqual(e.commitAll(), "", "空的時候送出空字串")
    }

    func testResetClearsEverything() throws {
        let e = try engine(typing: "zhongguo")
        e.reset()
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.composing, "")
        XCTAssertEqual(e.preedit, "")
    }

    // MARK: - 效能

    func testThirtyLettersConvertQuickly() throws {
        // 我今天去北京大学看朋友（34 個字母、11 音節）
        let keys = "wojintianqubeijingdaxuekanpengyou"
        XCTAssertGreaterThanOrEqual(keys.count, 30)
        let lex = try lexicon()
        let start = Date()
        let e = PinyinEngine(lexicon: lex)
        typeAll(e, keys)
        let preedit = e.preedit
        let candidates = e.candidates
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(preedit, "我今天去北京大学看朋友")
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThan(elapsed, 0.050, "30+ 字母轉換＋候選花了 \(elapsed * 1000) ms")

        // 每打一個字母就重算一次（鍵盤實際的呼叫方式），每鍵也要快；縮寫字串（區間查詢）最壞
        for text in [keys, "zgrmghgwsbjdxqhdxzgkxy"] {
            let e2 = PinyinEngine(lexicon: lex)
            var worst = 0.0
            for ch in text {
                let t = Date()
                e2.type(ch)
                _ = e2.preedit
                _ = e2.candidates
                worst = max(worst, Date().timeIntervalSince(t))
            }
            XCTAssertLessThan(worst, 0.050, "\(text) 最慢一鍵 \(worst * 1000) ms")
        }
    }

    // MARK: - 記憶體

    /// 設計上：詞庫以 .alwaysMapped 開檔，常駐 Swift 物件只有音節表（415 筆＋前綴區間），
    /// 3.9 萬把拼音鍵與 6.5 萬筆詞條都留在映射的檔案裡。這裡同時驗「結構」與「實測 footprint」。
    /// footprint 儀器本身的反面對照在 ZhuyinTests.testFootprintInstrumentSeesAWholeFileRead。
    func testLexiconDoesNotLoadWholeFileIntoMemory() throws {
        let before = ZhuyinTests.physFootprint()
        let lex = try XCTUnwrap(PinyinLexicon(url: Self.dataURL))
        for s in ["shi", "ni", "hao", "zhong", "guo"] {
            _ = lex.lookup(syllables: [s])
        }
        _ = lex.lookup(prefixes: ["z", "g"])
        let after = ZhuyinTests.physFootprint()
        XCTAssertLessThan(lex.syllableCount, 1_000, "常駐表只能是音節表，不是整份詞庫")
        XCTAssertGreaterThan(lex.entryCount, 60_000, "詞條確實在檔案裡")
        let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: Self.dataURL.path)[.size] as? Int)
        if let before, let after {
            let delta = after - before
            XCTAssertLessThan(delta, fileSize / 2,
                              "開詞庫後 footprint 增加 \(delta) bytes，接近整檔 \(fileSize) bytes → 疑似被整份讀進記憶體")
        }
    }

    func testMalformedDataIsRejected() throws {
        let good = try Data(contentsOf: Self.dataURL)
        XCTAssertNotNil(PinyinLexicon(data: good))
        XCTAssertNil(PinyinLexicon(data: Data()), "空資料")
        var wrongMagic = good
        wrongMagic[0] = UInt8(ascii: "X")
        XCTAssertNil(PinyinLexicon(data: wrongMagic), "magic 不符")
        XCTAssertNil(PinyinLexicon(data: good.prefix(64)), "截斷的檔案")
        let zhuyin = ZhuyinTests.dataURL
        if let z = try? Data(contentsOf: zhuyin) {
            XCTAssertNil(PinyinLexicon(data: z), "注音詞庫不能被當成拼音詞庫開")
        }
    }
}
