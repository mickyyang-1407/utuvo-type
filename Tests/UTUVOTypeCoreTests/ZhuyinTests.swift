import Foundation
import XCTest
@testable import UTUVOTypeCore

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

    func testCandidatesCanUseASmallerDisplayLimit() throws {
        let e = try makeEngine()
        typeAll(e, "ㄕˋ")
        XCTAssertEqual(e.candidates(limit: 0), [])
        let limited = e.candidates(limit: 3)
        XCTAssertLessThanOrEqual(limited.count, 3)
        XCTAssertEqual(limited.first?.text, e.candidates.first?.text)
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

        // 0.2.5 起：尾端沒收尾的音節（ㄅ 單獨）也當預測一起轉換，送出的就是候選列第一格顯示的（conversion）。
        // 組不出任何音節的符號仍原樣送出、不吞字（見 ZhuyinPredictionTests.testUnknownComposerFallsBackToSymbols）。
        typeAll(e, "ㄋㄧˇㄅ")
        let shown = e.conversion
        XCTAssertFalse(shown.contains("ㄅ"), "得到 \(shown)")
        XCTAssertEqual(e.commitAll(), shown)
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
    /// 13 萬把讀音鍵與 17 萬筆詞條都留在映射的檔案裡。
    /// 主檢查是結構：詞庫位元組就是 zhuyin.dat 的映射（跟 heap 歷史、測試順序無關）。
    /// footprint 前後差只在同一狀態下的整檔讀入對照看得見時才斷言（FootprintGate），看不見會印原因。
    func testLexiconDoesNotLoadWholeFileIntoMemory() throws {
        try MappedFileProbe.requireAvailable()
        let fileSize = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: Self.dataURL.path)[.size] as? Int)
        let (lex, delta) = try FootprintGate.measure("ZhuyinLexicon(url:)", wholeFileReadOf: Self.dataURL) {
            let lex = try XCTUnwrap(ZhuyinLexicon(url: Self.dataURL))
            for r in ["ㄕˋ", "ㄋㄧˇ", "ㄏㄠˇ", "ㄊㄞˊ", "ㄅㄟˇ"] {
                _ = lex.lookup(readings: [r][...])
            }
            return lex
        }
        XCTAssertLessThan(lex.syllableCount, 2_000, "常駐表只能是音節表，不是整份詞庫")
        XCTAssertGreaterThan(lex.entryCount, 150_000, "詞條確實在檔案裡")
        let why = lex.withBackingBytes { MappedFileProbe.mismatch($0, wholeFile: Self.dataURL) }
        XCTAssertNil(why, "詞庫位元組不是 zhuyin.dat 的映射 → 被整份讀進記憶體了：\(why ?? "")")
        if let delta {
            XCTAssertLessThan(delta, fileSize / 2,
                              "開詞庫後 footprint 增加 \(delta) bytes，接近整檔 \(fileSize) bytes → 疑似被整份讀進記憶體")
        }
    }

    /// 上一條結構檢查的反面對照，每種測試順序都必須成立：
    /// - 整份讀進 heap 的詞庫（拿掉 .alwaysMapped 的退化）一定被判「不是檔案映射」；
    /// - 映射了、但映的是另一個檔（內容一模一樣的複製檔）也不算。
    /// 舊版的對照是 footprint 量整檔讀入，完整測試後段 heap 重用已釋放記憶體時量到 0、紅綠看順序；
    /// 那個對照改在 FootprintGate 裡、跟受測量測同一狀態下跑，看不見就印原因、不斷言。
    func testMappingProbeRejectsHeapCopyAndOtherFile() throws {
        try MappedFileProbe.requireAvailable()
        let heap = try XCTUnwrap(ZhuyinLexicon(data: try Data(contentsOf: Self.dataURL)))
        let whyHeap = heap.withBackingBytes { MappedFileProbe.mismatch($0, wholeFile: Self.dataURL) }
        XCTAssertNotNil(whyHeap, "整份讀進 heap 的詞庫被判成 zhuyin.dat 的映射 → 結構檢查是空心的")
        XCTAssertTrue(whyHeap?.contains("不是檔案映射") ?? false, "理由應該是匿名記憶體，實際：\(whyHeap ?? "nil")")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fx10-mapping-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let twin = dir.appendingPathComponent("zhuyin.dat")
        try FileManager.default.copyItem(at: Self.dataURL, to: twin)
        // 直接映射，不經 ZhuyinLexicon(url:)：這條驗的是儀器本身，不能跟著受測的產品程式碼一起壞
        let mappedTwin = try XCTUnwrap(ZhuyinLexicon(data: try Data(contentsOf: twin, options: .alwaysMapped)))
        let whyTwinOK = mappedTwin.withBackingBytes { MappedFileProbe.mismatch($0, wholeFile: twin) }
        XCTAssertNil(whyTwinOK, "正面對照：複製檔自己的映射要被認出：\(whyTwinOK ?? "")")
        let whyTwin = mappedTwin.withBackingBytes { MappedFileProbe.mismatch($0, wholeFile: Self.dataURL) }
        XCTAssertNotNil(whyTwin, "映射的是另一個檔卻被判成 zhuyin.dat → 只看「有沒有映射」、沒看是哪個檔")
        XCTAssertTrue(whyTwin?.contains("別的檔") ?? false, "理由應該是別的檔，實際：\(whyTwin ?? "nil")")
    }
}
