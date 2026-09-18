import Foundation
import XCTest
@testable import UTUVOTypeCore
#if canImport(Darwin)
import Darwin
#endif

/// 注音引擎：組字器、詞庫（mmap 二分搜尋）、整句轉換、候選、效能與記憶體。
/// 詞庫走 repo 裡真正出貨的 ios/Keyboard/Resources/zhuyin.dat（以 #filePath 定位），
/// 不用合成的小詞庫——要驗的是鍵盤實際會拿到的資料。
final class ZhuyinTests: XCTestCase {

    static let dataURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // UTUVOTypeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("ios/Keyboard/Resources/zhuyin.dat")

    static let sharedLexicon: ZhuyinLexicon? = ZhuyinLexicon(url: dataURL)

    private func makeEngine() throws -> ZhuyinEngine {
        let lexicon = try XCTUnwrap(Self.sharedLexicon, "找不到或無法解析 \(Self.dataURL.path)")
        return ZhuyinEngine(lexicon: lexicon)
    }

    /// 依序打字；空白字元＝空白鍵（一聲收尾）。
    private func typeAll(_ engine: ZhuyinEngine, _ keys: String) {
        for ch in keys {
            if ch == " " { engine.space() } else { engine.type(ch) }
        }
    }

    // MARK: - 組字器

    func testComposerSlotReplacement() {
        var c = ZhuyinComposer()
        c.insert("ㄅ")
        c.insert("ㄚ")
        XCTAssertEqual(c.composing, "ㄅㄚ")
        c.insert("ㄆ")                       // 同槽（聲母）→ 取代
        XCTAssertEqual(c.composing, "ㄆㄚ")
        c.insert("ㄛ")                       // 同槽（韻母）→ 取代
        XCTAssertEqual(c.composing, "ㄆㄛ")
        c.insert("ㄧ")                       // 介音插在中間，不看打字順序
        XCTAssertEqual(c.composing, "ㄆㄧㄛ")
        XCTAssertFalse(c.insert("A"), "非注音符號不接受")
        XCTAssertFalse(c.insert("ˇ"), "聲調不進槽位")
        XCTAssertEqual(c.syllable(tone: "ˇ"), "ㄆㄧㄛˇ")
        XCTAssertEqual(c.syllable(tone: nil), "ㄆㄧㄛ")
        XCTAssertEqual(c.syllable(tone: "ˉ"), "ㄆㄧㄛ", "ˉ＝一聲，不標記")
    }

    func testToneCompletesSyllable() throws {
        let e = try makeEngine()
        e.type("ㄋ"); e.type("ㄧ")
        XCTAssertEqual(e.readings, [])
        XCTAssertEqual(e.composing, "ㄋㄧ")
        XCTAssertTrue(e.type("ˇ"))
        XCTAssertEqual(e.readings, ["ㄋㄧˇ"])
        XCTAssertEqual(e.composing, "")
    }

    func testSpaceCompletesAsFirstTone() throws {
        let e = try makeEngine()
        XCTAssertFalse(e.space(), "沒有正在組的音節時空白鍵是 no-op")
        XCTAssertTrue(e.isEmpty)
        e.type("ㄊ"); e.type("ㄧ"); e.type("ㄢ")
        XCTAssertTrue(e.space())
        XCTAssertEqual(e.readings, ["ㄊㄧㄢ"])
        XCTAssertEqual(e.composing, "")
        XCTAssertFalse(e.space(), "再按一次空白：沒有在組的音節 → 交給呼叫端")
        XCTAssertEqual(e.readings, ["ㄊㄧㄢ"])
    }

    func testInvalidSyllableAndStrayToneAreRejected() throws {
        let e = try makeEngine()
        XCTAssertFalse(e.type("ˋ"), "空的時候打聲調不接受")
        e.type("ㄅ")
        XCTAssertFalse(e.type("ˋ"), "ㄅˋ 不是合法音節，拒絕並保留原狀")
        XCTAssertEqual(e.composing, "ㄅ")
        XCTAssertEqual(e.readings, [])
        XCTAssertFalse(e.type("x"))
    }

    func testBackspaceRemovesSymbolThenSyllable() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄠ")
        XCTAssertEqual(e.readings, ["ㄋㄧˇ"])
        XCTAssertEqual(e.composing, "ㄏㄠ")
        XCTAssertTrue(e.backspace())
        XCTAssertEqual(e.composing, "ㄏ")
        XCTAssertTrue(e.backspace())
        XCTAssertEqual(e.composing, "")
        XCTAssertEqual(e.readings, ["ㄋㄧˇ"])
        XCTAssertTrue(e.backspace(), "沒有在組的符號 → 刪整個上一個音節")
        XCTAssertEqual(e.readings, [])
        XCTAssertTrue(e.isEmpty)
        XCTAssertFalse(e.backspace(), "空的回 false")
    }

    // MARK: - 詞庫

    func testLexiconLookupIsBestFirst() throws {
        let lex = try XCTUnwrap(Self.sharedLexicon)
        let shi = lex.lookup(readings: ["ㄕˋ"][...])
        XCTAssertEqual(shi.first?.text, "是")
        XCTAssertEqual(zip(shi, shi.dropFirst()).allSatisfy { $0.score >= $1.score }, true, "分數要由高到低")
        XCTAssertEqual(lex.lookup(readings: ["ㄋㄧˇ", "ㄏㄠˇ"][...]).first?.text, "你好")
        XCTAssertTrue(lex.lookup(readings: ["ㄅˋ"][...]).isEmpty, "不存在的音節查無結果")
        XCTAssertTrue(lex.hasPhrase(withPrefix: ["ㄓㄨㄥ", "ㄏㄨㄚˊ"][...]), "中華… 有更長的詞")
        XCTAssertFalse(lex.hasPhrase(withPrefix: ["ㄕˋ", "ㄕˋ", "ㄕˋ", "ㄕˋ", "ㄕˋ", "ㄕˋ"][...]))
    }

    func testLookupIgnoringTone() throws {
        let lex = try XCTUnwrap(Self.sharedLexicon)
        let texts = lex.lookupIgnoringTone(readings: ["ㄋㄧ", "ㄏㄠ"][...]).map(\.text)
        XCTAssertEqual(texts.first, "你好", "沒打聲調也要找得到 ㄋㄧˇ-ㄏㄠˇ")
        let single = lex.lookupIgnoringTone(readings: ["ㄕ"][...]).map(\.text)
        XCTAssertTrue(single.contains("是") && single.contains("十") && single.contains("師"))
    }

    // MARK: - 轉換與候選

    func testNiHaoConvertsToNiHao() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄠˇ")
        XCTAssertEqual(e.readings, ["ㄋㄧˇ", "ㄏㄠˇ"])
        XCTAssertEqual(e.preedit, "你好")
    }

    func testTaipei() throws {
        let e = try makeEngine()
        typeAll(e, "ㄊㄞˊㄅㄟˇ")
        XCTAssertTrue(["台北", "臺北"].contains(e.preedit), "得到 \(e.preedit)")
    }

    func testMultiSyllablePhrases() throws {
        let cases: [(String, String)] = [
            ("ㄓㄨㄥ ㄏㄨㄚˊㄇㄧㄣˊㄍㄨㄛˊ", "中華民國"),
            ("ㄊㄞˊㄅㄟˇㄕˋ", "台北市"),
            ("ㄉㄧㄢˋㄋㄠˇ", "電腦"),
            ("ㄐㄧˋㄙㄨㄢˋㄐㄧ ", "計算機"),
        ]
        for (keys, expected) in cases {
            let e = try makeEngine()
            typeAll(e, keys)
            XCTAssertEqual(e.preedit, expected, "輸入 \(keys)")
        }
    }

    func testPreeditIncludesDanglingComposingSymbols() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄠ")
        XCTAssertEqual(e.preedit, "你ㄏㄠ")
    }

    func testCandidatesForShiIncludeCommonCharacters() throws {
        let e = try makeEngine()
        typeAll(e, "ㄕˋ")
        let texts = e.candidates.map(\.text)
        for ch in ["是", "事", "市"] {
            XCTAssertTrue(texts.contains(ch), "ㄕˋ 候選缺 \(ch)")
        }
        XCTAssertEqual(texts.first, "是")
        XCTAssertLessThanOrEqual(texts.count, ZhuyinEngine.candidateLimit)
        XCTAssertTrue(e.candidates.allSatisfy { $0.readingCount == 1 })
    }

    func testCandidatesAreLongestFirstAndIncludeSingles() throws {
        let e = try makeEngine()
        typeAll(e, "ㄊㄞˊㄅㄟˇㄕˋ")
        let c = e.candidates
        XCTAssertEqual(c.first, ZhuyinCandidate(text: "台北市", readingCount: 3))
        let counts = c.map(\.readingCount)
        XCTAssertEqual(counts, counts.sorted(by: >), "長詞在前")
        XCTAssertTrue(c.contains(ZhuyinCandidate(text: "台北", readingCount: 2)))
        XCTAssertTrue(c.contains(ZhuyinCandidate(text: "台", readingCount: 1)))
    }

    func testSelectRemovesReadingsAndReturnsText() throws {
        let e = try makeEngine()
        typeAll(e, "ㄊㄞˊㄅㄟˇㄕˋ")
        let taipei = try XCTUnwrap(e.candidates.first { $0.readingCount == 2 })
        XCTAssertEqual(e.select(taipei), taipei.text)
        XCTAssertEqual(e.readings, ["ㄕˋ"])
        XCTAssertEqual(e.candidates.first?.text, "是")
        XCTAssertEqual(e.select(ZhuyinCandidate(text: "過期", readingCount: 5)), "", "過期候選不動緩衝區")
        XCTAssertEqual(e.readings, ["ㄕˋ"])
    }

    func testCommitAllReturnsConversionAndResets() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄠˇ")
        XCTAssertEqual(e.commitAll(), "你好")
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.preedit, "")
        XCTAssertEqual(e.candidates, [])

        // 尾端在組的音節：一聲合法就一起轉換（ㄊㄧㄢ → 天）
        typeAll(e, "ㄐㄧㄣ ㄊㄧㄢ")
        XCTAssertEqual(e.readings, ["ㄐㄧㄣ"])
        XCTAssertEqual(e.composing, "ㄊㄧㄢ")
        XCTAssertEqual(e.commitAll(), "今天")
        XCTAssertTrue(e.isEmpty)

        // 一聲不合法（ㄅ 單獨）→ 原樣附上注音，不吞使用者的字
        typeAll(e, "ㄋㄧˇㄅ")
        XCTAssertEqual(e.commitAll(), "你ㄅ")
        XCTAssertTrue(e.isEmpty)
    }

    func testResetClearsEverything() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄠ")
        e.reset()
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.readings, [])
        XCTAssertEqual(e.composing, "")
    }

    // MARK: - 效能

    func testTwentySyllablesConvertQuickly() throws {
        // 我們今天在台北市的電腦公司開會討論新計畫（20 音節）
        let keys = "ㄨㄛˇㄇㄣ˙ㄐㄧㄣ ㄊㄧㄢ ㄗㄞˋㄊㄞˊㄅㄟˇㄕˋㄉㄜ˙ㄉㄧㄢˋㄋㄠˇㄍㄨㄥ ㄙ ㄎㄞ ㄏㄨㄟˋㄊㄠˇㄌㄨㄣˋㄒㄧㄣ ㄐㄧˋㄏㄨㄚˋ"
        let lexicon = try XCTUnwrap(Self.sharedLexicon)
        let start = Date()
        let e = ZhuyinEngine(lexicon: lexicon)
        typeAll(e, keys)
        let preedit = e.preedit
        let candidates = e.candidates
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(e.readings.count, 20)
        XCTAssertEqual(preedit, "我們今天在台北市的電腦公司開會討論新計畫")
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThan(elapsed, 0.050, "20 音節轉換＋候選花了 \(elapsed * 1000) ms")

        // 每打一個音節就重算一次（鍵盤實際的呼叫方式），總計也要快
        let e2 = ZhuyinEngine(lexicon: lexicon)
        let t2 = Date()
        for ch in keys {
            if ch == " " { e2.space() } else { e2.type(ch) }
            _ = e2.preedit
            _ = e2.candidates
        }
        let perKey = Date().timeIntervalSince(t2) / Double(keys.count)
        XCTAssertLessThan(perKey, 0.050, "每鍵 \(perKey * 1000) ms")
    }

    // MARK: - 記憶體

    /// 設計上：詞庫以 .alwaysMapped 開檔，常駐 Swift 物件只有音節表（約 1,400 筆），
    /// 13 萬把讀音鍵與 17 萬筆詞條都留在映射的檔案裡。這裡同時驗「結構」與「實測 footprint」。
    func testLexiconDoesNotLoadWholeFileIntoMemory() throws {
        let before = Self.physFootprint()
        let lex = try XCTUnwrap(ZhuyinLexicon(url: Self.dataURL))
        for r in ["ㄕˋ", "ㄋㄧˇ", "ㄏㄠˇ", "ㄊㄞˊ", "ㄅㄟˇ"] {
            _ = lex.lookup(readings: [r][...])
        }
        let after = Self.physFootprint()
        XCTAssertLessThan(lex.syllableCount, 2_000, "常駐表只能是音節表，不是整份詞庫")
        XCTAssertGreaterThan(lex.entryCount, 150_000, "詞條確實在檔案裡")
        let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: Self.dataURL.path)[.size] as? Int)
        if let before, let after {
            let delta = after - before
            XCTAssertLessThan(delta, fileSize / 2,
                              "開詞庫後 footprint 增加 \(delta) bytes，接近整檔 \(fileSize) bytes → 疑似被整份讀進記憶體")
        }
    }

    /// 上一條的反面對照：同一個儀器量「真的整份讀進記憶體」要看得到。量不到＝上一條永遠綠、沒在檢查。
    func testFootprintInstrumentSeesAWholeFileRead() throws {
        guard let before = Self.physFootprint() else { throw XCTSkip("此平台沒有 phys_footprint") }
        let copy = try Data(contentsOf: Self.dataURL)          // 不映射：整份複製進 heap
        let bytes = copy.withUnsafeBytes { Array($0) }        // 再逐位元組碰一次，確保頁面真的進實體記憶體
        let after = try XCTUnwrap(Self.physFootprint())
        XCTAssertEqual(bytes.count, copy.count)
        XCTAssertGreaterThan(after - before, copy.count / 2,
                             "整份讀進記憶體卻只增加 \(after - before) bytes → footprint 儀器量不到，記憶體測試是空心的")
    }

    /// 行程的 phys_footprint（Jetsam 用來判定鍵盤 extension 記憶體上限的同一個數字）。
    static func physFootprint() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) : nil
        #else
        return nil
        #endif
    }
}
