import Foundation
import XCTest
@testable import UTUVOTypeCore

/// 注音「邊打邊出候選」：沒收尾的音節、簡拼（只打聲母）、不打聲調、倒退與還原。
/// 用出貨的 ios/Keyboard/Resources/zhuyin.dat。
final class ZhuyinPredictionTests: XCTestCase {

    private func makeEngine() throws -> ZhuyinEngine {
        ZhuyinEngine(lexicon: try XCTUnwrap(ZhuyinTests.sharedLexicon))
    }

    /// 依序打字；空白字元＝空白鍵。
    private func typeAll(_ engine: ZhuyinEngine, _ keys: String) {
        for ch in keys {
            if ch == " " { engine.space() } else { engine.type(ch) }
        }
    }

    private func texts(_ e: ZhuyinEngine, limit: Int = 8) -> [String] { e.candidates(limit: limit).map(\.text) }

    func testSingleInitialAlreadyHasCandidates() throws {
        let e = try makeEngine()
        e.type("ㄋ")
        XCTAssertEqual(e.composing, "ㄋ")
        let t = texts(e)
        XCTAssertTrue(t.contains("你"), "只打 ㄋ 就要有「你」，得到 \(t)")
        XCTAssertTrue(e.candidates(limit: 8).allSatisfy { $0.readingCount == 1 })
    }

    func testToneLessSyllableRanksExactFirst() throws {
        let e = try makeEngine()
        typeAll(e, "ㄕ")
        XCTAssertEqual(texts(e).first, "是", "ㄕ（不分聲調）第一個應該是「是」，得到 \(texts(e))")
        let f = try makeEngine()
        typeAll(f, "ㄋㄧ")
        XCTAssertEqual(texts(f).first, "你", "ㄋㄧ → 你（ㄋㄧˇ 只差聲調，不扣分），得到 \(texts(f))")
    }

    func testInitialsOnlyAbbreviation() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄏ")
        XCTAssertEqual(e.readings, ["ㄋ"], "第二個聲母擠開第一個音節")
        XCTAssertEqual(e.composing, "ㄏ")
        // 排序完全照小麥注音的詞頻：ㄋㄏ 開頭的兩字詞裡 女孩（−4.15）、年後…比 你好（−5.09）常見，
        // 所以 你好 不會是第一個，但要在鍵盤候選列（20 格）裡。
        let c = e.candidates(limit: 20)
        XCTAssertTrue(c.contains(ZhuyinCandidate(text: "你好", readingCount: 2)), "ㄋㄏ → 要有 你好，得到 \(c.map(\.text))")
        XCTAssertTrue(c.prefix(2).allSatisfy { $0.readingCount == 2 }, "兩字詞排在前面")
        XCTAssertTrue(c.contains { $0.readingCount == 1 && $0.text == "你" }, "單字候選也要在（多字詞不能把單字擠光）")
        XCTAssertTrue(e.candidates(limit: 8).contains { $0.readingCount == 1 }, "只顯示 8 格時也留位置給單字")
        XCTAssertEqual(e.conversion, e.candidates(limit: 1).first?.text, "整句送出＝最佳的兩字詞")
        XCTAssertEqual(e.preedit, "ㄋㄏ", "輸入框顯示打了什麼")
    }

    func testLongerAbbreviations() throws {
        let cases: [(String, String)] = [
            ("ㄊㄅ", "台北"),
            ("ㄉㄋ", "電腦"),
            ("ㄓㄏㄇㄍ", "中華民國"),
        ]
        for (keys, expected) in cases {
            let e = try makeEngine()
            typeAll(e, keys)
            let t = texts(e, limit: 10)
            XCTAssertTrue(t.contains(expected) || t.contains(expected.replacingOccurrences(of: "台", with: "臺")),
                          "\(keys) 應該有 \(expected)，得到 \(t)")
        }
    }

    func testToneLessSyllablesConvert() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧㄏㄠ")
        XCTAssertEqual(e.readings, ["ㄋㄧ"])
        XCTAssertEqual(e.composing, "ㄏㄠ")
        XCTAssertEqual(e.candidates(limit: 8).first, ZhuyinCandidate(text: "你好", readingCount: 2))
        XCTAssertEqual(e.conversion, "你好")
        XCTAssertTrue(e.hasUncompletedSyllables)
        XCTAssertFalse(e.space(), "有沒收尾的音節時空白不當一聲（交給呼叫端整句送出）")
        XCTAssertEqual(e.commitAll(), "你好")
        XCTAssertTrue(e.isEmpty)
    }

    func testMixedToneAndToneLess() throws {
        let e = try makeEngine()
        typeAll(e, "ㄐㄧㄣ ㄊㄧㄢ ㄏㄠˇ")
        XCTAssertEqual(e.conversion, "今天好")
        let f = try makeEngine()
        typeAll(f, "ㄐㄊ")          // 今天 的簡拼
        XCTAssertTrue(texts(f, limit: 10).contains("今天"), "ㄐㄊ 應該有 今天，得到 \(texts(f, limit: 10))")
    }

    func testSelectingAbbreviatedCandidateClearsComposer() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄏ")
        let nihao = try XCTUnwrap(e.candidates(limit: 20).first { $0.text == "你好" })
        XCTAssertEqual(e.select(nihao), "你好")
        XCTAssertTrue(e.isEmpty, "選了涵蓋正在組的音節的候選，整個緩衝區清空")

        typeAll(e, "ㄋㄏ")
        let ni = try XCTUnwrap(e.candidates(limit: 20).first { $0.readingCount == 1 && $0.text == "你" })
        XCTAssertEqual(e.select(ni), "你")
        XCTAssertEqual(e.readings, [])
        XCTAssertEqual(e.composing, "ㄏ", "剩下的沒收尾音節回到正在組")
        XCTAssertTrue(texts(e).contains("好"))
    }

    func testBackspaceReopensUncompletedSyllable() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄏ")
        XCTAssertTrue(e.backspace())
        XCTAssertEqual(e.readings, [])
        XCTAssertEqual(e.composing, "ㄋ", "刪掉 ㄏ 之後回到正在組 ㄋ")
        XCTAssertTrue(e.type("ㄧ"), "可以接著組成 ㄋㄧ")
        XCTAssertTrue(e.type("ˇ"))
        XCTAssertEqual(e.readings, ["ㄋㄧˇ"])

        let f = try makeEngine()
        typeAll(f, "ㄋㄏㄠˇ")
        XCTAssertEqual(f.readings, ["ㄋ", "ㄏㄠˇ"])
        XCTAssertTrue(f.backspace(), "刪整個 ㄏㄠˇ")
        XCTAssertEqual(f.readings, [])
        XCTAssertEqual(f.composing, "ㄋ")
    }

    func testOnlyConflictingSymbolsStartANewSyllable() throws {
        let e = try makeEngine()
        typeAll(e, "ㄓㄨㄥ")            // 聲母→介音→韻母：同一個音節
        XCTAssertEqual(e.readings, [])
        XCTAssertEqual(e.composing, "ㄓㄨㄥ")
        e.type("ㄨ")                   // 介音槽後面已經有韻母 → 新音節
        XCTAssertEqual(e.readings, ["ㄓㄨㄥ"])
        XCTAssertEqual(e.composing, "ㄨ")
    }

    func testCompleteToneInputBehavesAsBefore() throws {
        let e = try makeEngine()
        typeAll(e, "ㄊㄞˊㄅㄟˇㄕˋ")
        XCTAssertFalse(e.hasUncompletedSyllables)
        XCTAssertEqual(e.candidates.first, ZhuyinCandidate(text: "台北市", readingCount: 3))
        XCTAssertEqual(e.conversion, e.preedit)
    }

    func testUnknownComposerFallsBackToSymbols() throws {
        let e = try makeEngine()
        typeAll(e, "ㄅㄩ")              // 沒有任何音節是 ㄅㄩ…
        XCTAssertEqual(e.conversion, "ㄅㄩ", "組不出音節時原樣送出，不吞字")
    }

    func testStateRestoreRoundTrips() throws {
        let e = try makeEngine()
        typeAll(e, "ㄋㄧˇㄏㄓ")
        let state = e.state
        let preedit = e.preedit, candidates = e.candidates(limit: 8), conversion = e.conversion
        _ = e.commitAll()
        XCTAssertTrue(e.isEmpty)
        e.restore(state)
        XCTAssertEqual(e.preedit, preedit)
        XCTAssertEqual(e.conversion, conversion)
        XCTAssertEqual(e.candidates(limit: 8), candidates)
        XCTAssertEqual(e.composing, "ㄓ")
    }

    // MARK: - 效能

    /// 最壞情況之一：一路只打聲母（每個位置都是幾十個音節）。每鍵重算 preedit＋conversion＋候選也要快。
    func testManyInitialsStayFast() throws {
        let e = try makeEngine()
        let keys = "ㄨㄇㄐㄊㄗㄊㄅㄕㄉㄉㄋㄍㄙㄎㄏㄊㄌㄒㄐㄏ"
        var worst = 0.0
        for ch in keys {
            let t = Date()
            e.type(ch)
            _ = e.preedit
            _ = e.conversion
            _ = e.candidates(limit: 8)
            worst = max(worst, Date().timeIntervalSince(t))
        }
        XCTAssertEqual(e.readings.count, 19)
        XCTAssertLessThan(worst, 0.050, "只打聲母 20 個，最慢一鍵 \(worst * 1000) ms")
    }
}
