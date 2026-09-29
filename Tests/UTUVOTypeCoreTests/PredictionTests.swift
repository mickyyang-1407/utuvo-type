import Foundation
import XCTest
@testable import UTUVOTypeCore
#if canImport(AppKit)
import AppKit
#endif

/// 聯想詞（選字後建議下一段）與英文建議列。聯想詞走出貨的 ios/Keyboard/Resources/assoc-*.dat。
final class PredictionTests: XCTestCase {

    static func resource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ios/Keyboard/Resources/\(name)")
    }

    static let hant = PhraseAssociations(url: resource("assoc-hant.dat"))
    static let hans = PhraseAssociations(url: resource("assoc-hans.dat"))

    // MARK: - 聯想詞

    func testTraditionalAssociationsAfterNiHao() throws {
        let a = try XCTUnwrap(Self.hant)
        XCTAssertGreaterThan(a.phraseCount, 50_000)
        let next = a.continuations(after: "你好", limit: 8)
        XCTAssertEqual(next.first, "嗎", "你好 → 你好嗎（小麥注音聯想詞），得到 \(next)")
        XCTAssertTrue(next.contains("像"), "你好 的兩字前文用完後，用「好」補：好像，得到 \(next)")
        XCTAssertEqual(next.count, 8)
        XCTAssertEqual(Set(next).count, next.count, "不重複")
    }

    func testAssociationsFollowScoreOrder() throws {
        let a = try XCTUnwrap(Self.hant)
        // 小麥注音 data.txt：你們 −3.62 > 你的 > 你要…（依分數由高到低）
        XCTAssertEqual(Array(a.continuations(ofPrefix: "你").prefix(3)), ["們", "的", "要"])
        XCTAssertTrue(a.continuations(after: "", limit: 5).isEmpty)
        XCTAssertTrue(a.continuations(after: "你好", limit: 0).isEmpty)
        XCTAssertTrue(a.continuations(after: "🙂", limit: 5).isEmpty, "查不到的前文回空")
        XCTAssertTrue(a.continuations(after: "abc", limit: 5).isEmpty)
    }

    func testLongContextUsesItsTail() throws {
        let a = try XCTUnwrap(Self.hant)
        let next = a.continuations(after: "我們今天說你好", limit: 3)
        XCTAssertEqual(next.first, "嗎", "只看結尾的「你好」，得到 \(next)")
    }

    func testSimplifiedAssociations() throws {
        let a = try XCTUnwrap(Self.hans)
        XCTAssertEqual(a.continuations(after: "你好", limit: 5).first, "啊")
        let china = a.continuations(after: "中国", limit: 5)
        XCTAssertTrue(china.contains("人"), "中国 → 中国人，得到 \(china)")
        XCTAssertTrue(a.continuations(after: "谢谢", limit: 5).contains("大家"))
    }

    func testMalformedDataIsRejected() {
        XCTAssertNil(PhraseAssociations(data: Data("nope".utf8)))
        XCTAssertNil(PhraseAssociations(data: Data("UTAS".utf8) + Data(repeating: 0, count: 16)), "版本 0 不接受")
        var header = Data("UTAS".utf8)
        for v: UInt32 in [1, 1_000, 20, 4_020] { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        XCTAssertNil(PhraseAssociations(data: header), "索引超出檔案")
    }

    func testAssociationLookupIsFast() throws {
        let a = try XCTUnwrap(Self.hant)
        let start = Date()
        for ch in "的一是不了人我在有他這中大來上國個到說們為子和你地出道也時年得就那要下以生會自著去之過家學對可她裡後小麼心多天而能好都然沒日於起還發成事只作當想看文無開手十用主行方又如前所本見經頭面公同三已老從動兩長" {
            _ = a.continuations(after: String(ch), limit: 20)
        }
        let per = Date().timeIntervalSince(start) / 100
        XCTAssertLessThan(per, 0.005, "最常見的 100 個字，每次查詢 \(per * 1000) ms")
    }

    // MARK: - 注音：選字後可以接聯想詞

    func testZhuyinCommitThenAssociate() throws {
        let e = ZhuyinEngine(lexicon: try XCTUnwrap(ZhuyinTests.sharedLexicon))
        for ch in "ㄋㄧˇㄏㄠˇ" { e.type(ch) }
        let picked = e.select(try XCTUnwrap(e.candidates(limit: 8).first))
        XCTAssertEqual(picked, "你好")
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(try XCTUnwrap(Self.hant).continuations(after: picked, limit: 8).first, "嗎")
    }

    func testZhuyinSpaceOnBareInitialDefersToCaller() throws {
        let e = ZhuyinEngine(lexicon: try XCTUnwrap(ZhuyinTests.sharedLexicon))
        e.type("ㄋ")
        XCTAssertFalse(e.space(), "只有聲母 ㄋ：一聲只對到注音符號本身，不收成它")
        XCTAssertEqual(e.composing, "ㄋ")
        XCTAssertFalse(e.conversion.contains("ㄋ"), "送出的是最佳猜測，不是符號：\(e.conversion)")
        let f = ZhuyinEngine(lexicon: try XCTUnwrap(ZhuyinTests.sharedLexicon))
        f.type("ㄙ")
        XCTAssertTrue(f.space(), "ㄙ 一聲是真的字（思），照舊收尾")
        XCTAssertEqual(f.readings, ["ㄙ"])
    }

    // MARK: - 英文

    func testCurrentWord() {
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "Hello wor"), "wor")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "I don't kn"), "kn")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "I don't"), "don't")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "end. "), "")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "abc,"), "")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "中文abc"), "abc")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "'quo"), "quo")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: nil), "")
        XCTAssertEqual(EnglishSuggestions.currentWord(before: "abc123"), "")
    }

    func testMatchCase() {
        XCTAssertEqual(EnglishSuggestions.matchCase("hello", to: "Hel"), "Hello")
        XCTAssertEqual(EnglishSuggestions.matchCase("hello", to: "HEL"), "HELLO")
        XCTAssertEqual(EnglishSuggestions.matchCase("hello", to: "hel"), "hello")
        XCTAssertEqual(EnglishSuggestions.matchCase("iPhone", to: "iph"), "iPhone")
        XCTAssertEqual(EnglishSuggestions.matchCase("hello", to: "H"), "Hello", "單一個大寫字母＝首字大寫，不是全大寫")
    }

    func testMergeOrdersUserWordsThenSpelling() {
        let terms = ["Dolby Atmos", "Atmosphere", "McBopomofo", "中文詞"]
        let s = EnglishSuggestions.merge(word: "atm", isMisspelled: true,
                                         completions: ["atmosphere", "atm"], guesses: ["arm", "atom"],
                                         userTerms: terms, limit: 8)
        XCTAssertEqual(s, ["Atmos", "Atmosphere", "arm", "atom"], "使用者詞優先、保留原寫法；拼錯時 guesses 在前；去掉跟打的一樣的與重複的")
        let ok = EnglishSuggestions.merge(word: "Hel", isMisspelled: false,
                                          completions: ["hello", "help", "held"], guesses: ["gel"],
                                          userTerms: [], limit: 3)
        XCTAssertEqual(ok, ["Hello", "Help", "Held"], "拼對時補完在前、照打的大小寫、不超過上限")
        XCTAssertEqual(EnglishSuggestions.merge(word: "", isMisspelled: false, completions: ["a"], guesses: [], userTerms: []), [])
    }

    #if canImport(AppKit)
    /// 端到端：拿 macOS 系統拼字字典（與 iOS UITextChecker 同一套英文字典）當來源，確認真的有補完與拼字建議。
    /// iOS 上的 UITextChecker 版本在 ios/iOSTests/EnglishSuggesterTests.swift。
    func testSystemSpellCheckerFeedsSuggestions() throws {
        let checker = NSSpellChecker.shared
        guard checker.setLanguage("en") || checker.setLanguage("en_US") else { throw XCTSkip("沒有英文拼字字典") }
        func suggest(_ word: String) -> [String] {
            let range = NSRange(location: 0, length: (word as NSString).length)
            let completions = checker.completions(forPartialWordRange: range, in: word, language: nil, inSpellDocumentWithTag: 0) ?? []
            let misspelled = checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound
            let guesses = misspelled ? (checker.guesses(forWordRange: range, in: word, language: nil, inSpellDocumentWithTag: 0) ?? []) : []
            return EnglishSuggestions.merge(word: word, isMisspelled: misspelled, completions: completions, guesses: guesses, userTerms: [])
        }
        XCTAssertTrue(suggest("hel").contains("hello"), "hel → hello，得到 \(suggest("hel"))")
        XCTAssertTrue(suggest("Tomor").contains("Tomorrow"), "Tomor → Tomorrow，得到 \(suggest("Tomor"))")
        XCTAssertTrue(suggest("recieve").contains("receive"), "拼錯的 recieve → receive，得到 \(suggest("recieve"))")
    }
    #endif
}
