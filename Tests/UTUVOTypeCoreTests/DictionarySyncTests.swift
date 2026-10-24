import XCTest
@testable import UTUVOTypeCore

final class DictionarySyncTests: XCTestCase {
    func testLastWriterWinsBothDirections() {
        var mac = DictionarySync()
        mac.set("cloud code", "Claude Code", at: 10)
        mac.set("jamin", "Gemini", at: 10)
        var phone = DictionarySync()
        phone.set("cloud code", "Claude Code 2", at: 20)   // 手機後改
        phone.set("除值", "儲值", at: 5)
        mac.remove("jamin", at: 30)                          // Mac 後刪

        let a = mac.merged(with: phone), b = phone.merged(with: mac)
        XCTAssertEqual(a, b, "合併結果不看順序")
        XCTAssertEqual(a.live, ["cloud code": "Claude Code 2", "除值": "儲值"])
    }

    func testDeletionTravelsButLaterReAddWins() {
        var a = DictionarySync(); a.set("x", "X", at: 1)
        var b = a
        b.remove("x", at: 2)
        XCTAssertEqual(a.merged(with: b).live, [:], "刪除要帶過去")
        a.set("x", "X!", at: 3)
        XCTAssertEqual(a.merged(with: b).live, ["x": "X!"], "刪了之後又加回來，較晚的贏")
    }

    func testTieIsDeterministic() {
        var a = DictionarySync(); a.set("k", "A", at: 5)
        var b = DictionarySync(); b.set("k", "B", at: 5)
        XCTAssertEqual(a.merged(with: b), b.merged(with: a))
        var c = DictionarySync(); c.set("k", "A", at: 5); c.remove("k", at: 5)
        XCTAssertEqual(a.merged(with: c).live, ["k": "A"], "同時間有值的贏")
    }

    func testReconcileRecordsOutOfBandEdits() {
        var s = DictionarySync(plain: ["a": "A", "b": "B"], at: 1)
        s.reconcile(with: ["a": "A", "c": "C", "b": "BB"], at: 9)
        XCTAssertEqual(s.live, ["a": "A", "b": "BB", "c": "C"])
        s.reconcile(with: ["a": "A"], at: 10)
        XCTAssertEqual(s.live, ["a": "A"])
        XCTAssertEqual(s.entries["a"]?.at, 1, "沒變的不動時間")
        XCTAssertNil(s.entries["b"]?.output)
        XCTAssertEqual(s.entries["b"]?.at, 10)
    }

    func testFileRoundTripAndLegacyPlainJSON() throws {
        var s = DictionarySync(); s.set("cloud code", "Claude Code", at: 1_789_000_000); s.remove("gone", at: 1)
        s.set("gone", "x", at: 0); s.remove("gone", at: 2)
        let back = try DictionarySync.decode(s.encoded())
        XCTAssertEqual(back, s)
        XCTAssertTrue(String(decoding: s.encoded(), as: UTF8.self).contains("\"format\" : \"utuvo-type-dictionary\""))
        let legacy = try DictionarySync.decode(Data(#"{"pik":"Pik"}"#.utf8))
        XCTAssertEqual(legacy.live, ["pik": "Pik"])
        XCTAssertThrowsError(try DictionarySync.decode(Data(#"{"format":"other","version":1,"entries":{}}"#.utf8)))
        XCTAssertThrowsError(try DictionarySync.decode(Data(#"{"format":"utuvo-type-dictionary","version":99,"entries":{}}"#.utf8)))
        XCTAssertThrowsError(try DictionarySync.decode(Data("hello".utf8)))
    }

    func testPruneOldTombstonesOnly() {
        var s = DictionarySync(); s.set("keep", "K", at: 0); s.set("old", "o", at: 0); s.remove("old", at: 1)
        s.set("new", "n", at: 0); s.remove("new", at: 1_000_000_000)
        let p = s.pruned(now: 1_000_000_000 + 10)
        XCTAssertNotNil(p.entries["keep"]); XCTAssertNil(p.entries["old"]); XCTAssertNotNil(p.entries["new"])
    }

    /// 給 Kotlin 對照用的固定樣本（Android 讀得懂 iPhone 的匯出檔）。
    func testFixtureMatchesAndroidReader() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../android/core/src/test/resources/dictionary-sync-fixture.json").standardized
        // 開源 repo 不含 android/：沒有對照樣本就明確略過（顯示 skipped，不是假綠）；內部 repo 一定要跑到。
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "android/ 不在這個 checkout（開源版）")
        let s = try DictionarySync.decode(Data(contentsOf: url))
        XCTAssertEqual(s.live, ["cloud code": "Claude Code", "Atmos": "Atmos"])
        XCTAssertNil(s.entries["jamin"]?.output)
    }

    // MARK: - 純詞表匯入（app-shell-6；Kotlin DictionarySyncTest 跑同樣的案例與同一份樣本）

    static let wordListFixtureWords = ["Atmos", "Pro Tools", "DAMI music", "Logic Pro", "Say \"Hi\", ok", "Dolby", "UTUVO", "unterminated quote"]

    func testWordListOneWordPerLineAndFirstCSVColumn() throws {
        let text = "\u{FEFF}Atmos\r\nPro Tools\n\n\"DAMI music\",note\nAtmos\n"
        XCTAssertFalse(DictionarySync.looksLikeJSON(Data(text.utf8)))
        XCTAssertEqual(try DictionarySync.parseWordList(Data(text.utf8)), ["Atmos", "Pro Tools", "DAMI music"])
    }

    func testWordListErrors() {
        XCTAssertThrowsError(try DictionarySync.parseWordList(Data())) { XCTAssertEqual($0 as? DictionarySync.WordListError, .noWords) }
        XCTAssertThrowsError(try DictionarySync.parseWordList(Data("\u{FEFF}\n  \r\n,x\n".utf8))) {
            XCTAssertEqual($0 as? DictionarySync.WordListError, .noWords)
        }
        let big = Data(repeating: UInt8(ascii: "a"), count: DictionarySync.maxWordListBytes + 1)
        XCTAssertThrowsError(try DictionarySync.parseWordList(big)) { XCTAssertEqual($0 as? DictionarySync.WordListError, .tooLarge) }
        var atLimit = Data(repeating: UInt8(ascii: "\n"), count: DictionarySync.maxWordListBytes - 1)
        atLimit.insert(UInt8(ascii: "a"), at: 0)
        XCTAssertEqual(try DictionarySync.parseWordList(atLimit), ["a"], "剛好 5 MB 可以")
    }

    func testJSONLookingContentIsNeverAWordList() throws {
        var s = DictionarySync(); s.set("cloud code", "Claude Code", at: 1)
        XCTAssertTrue(DictionarySync.looksLikeJSON(s.encoded()))
        XCTAssertTrue(DictionarySync.looksLikeJSON(Data("\u{FEFF}  \n {\"pik\":\"Pik\"}".utf8)))
        XCTAssertTrue(DictionarySync.looksLikeJSON(Data("[\"Atmos\"]".utf8)))
        let broken = Data("{\n  \"format\" : \"utuvo-type-dictionary\",\n  \"version\" : 1,\n".utf8)
        XCTAssertTrue(DictionarySync.looksLikeJSON(broken), "壞掉的匯出檔要走 decode（丟錯），不能被當成詞表")
        XCTAssertThrowsError(try DictionarySync.decode(broken))
        XCTAssertFalse(DictionarySync.looksLikeJSON(Data("Atmos\n{curly}\n".utf8)))
    }

    func testAddWordsKeepsExistingOutputsAndRevivesDeleted() {
        var s = DictionarySync(); s.set("Atmos", "Dolby Atmos", at: 1); s.set("gone", "x", at: 1); s.remove("gone", at: 2)
        XCTAssertEqual(s.newWords(["Atmos", "gone", "Pro Tools", "Pro Tools", " "]), ["gone", "Pro Tools"])
        XCTAssertEqual(s.addWords(["Atmos", "gone", "Pro Tools"], at: 10), ["gone", "Pro Tools"])
        XCTAssertEqual(s.live, ["Atmos": "Dolby Atmos", "gone": "gone", "Pro Tools": "Pro Tools"])
        XCTAssertEqual(s.entries["Pro Tools"]?.at, 10)
        XCTAssertEqual(s.entries["Atmos"]?.at, 1, "已經有的詞不動")
    }

    func testWordListFixtureMatchesAndroidParser() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../android/core/src/test/resources/dictionary-wordlist-fixture.txt").standardized
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "android/ 不在這個 checkout（開源版）")
        let data = try Data(contentsOf: url)
        XCTAssertFalse(DictionarySync.looksLikeJSON(data))
        XCTAssertEqual(try DictionarySync.parseWordList(data), Self.wordListFixtureWords)
    }

    func testDictionarySearchMatchesSourceOrOutputCaseInsensitive() {
        let entries: [(source: String, output: String)] = [("Atmos", "Atmos"), ("pik", "Pik"), ("除值", "儲值"), ("及時", "即時")]
        XCTAssertEqual(DictionarySync.search(entries, query: "ATMOS").map(\.source), ["Atmos"], "大小寫不敏感")
        XCTAssertEqual(DictionarySync.search(entries, query: "Pik").map(\.source), ["pik"], "輸出也要能被搜到")
        XCTAssertEqual(DictionarySync.search(entries, query: "儲").map(\.source), ["除值"])
        XCTAssertEqual(DictionarySync.search(entries, query: "   ").count, 4, "全空白等於沒搜")
        XCTAssertTrue(DictionarySync.search([], query: "y").isEmpty)
    }

    // MARK: - 來源標記（手動／自動，delivery-learning-4；Kotlin DictionarySyncTest／DictionarySourceTest 同規則、同一份樣本）

    static func sourceFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../android/core/src/test/resources/dictionary-sync-source-fixture.json").standardized
    }

    /// Android 匯出的 AUTO 標記經過 Mac／iPhone 匯入再匯出不能掉（以前 Swift 的 Entry 只有 output／at，標記一讀就丟）。
    func testAndroidAutoTagSurvivesMacRoundTrip() throws {
        let url = Self.sourceFixtureURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "android/ 不在這個 checkout（開源版）")
        let fromAndroid = try DictionarySync.decode(Data(contentsOf: url))
        var mac = DictionarySync()
        mac.set("除值", "儲值", at: 1)
        let exported = String(decoding: mac.merged(with: fromAndroid).encoded(), as: UTF8.self)
        XCTAssertTrue(exported.contains(#""source" : "AUTO""#), exported)
    }

    func testSourceFixtureDecodesLikeKotlin() throws {
        let url = Self.sourceFixtureURL()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "android/ 不在這個 checkout（開源版）")
        let s = try DictionarySync.decode(Data(contentsOf: url))
        XCTAssertEqual(s.entries["Atmus"]?.source, .auto)
        XCTAssertEqual(s.entries["UTUVO"]?.source, .auto)
        XCTAssertEqual(s.entries["cloud code"]?.source, .manual)
        XCTAssertEqual(s.entries["pik"]?.source, .manual, "缺欄位＝手動")
        XCTAssertEqual(s.entries["odd"]?.source, .manual, "看不懂的值＝手動，整份檔照樣讀得進來")
        XCTAssertNil(s.entries["gone"]?.output)
        XCTAssertEqual(s.autoTerms, ["Atmus", "UTUVO"], "墓碑不算")
        XCTAssertEqual(s.live, ["Atmus": "Atmos", "UTUVO": "UTUVO", "cloud code": "Claude Code", "pik": "Pik", "odd": "Odd"])
        XCTAssertEqual(try DictionarySync.decode(s.encoded()), s, "自己寫的檔讀回來一樣")
    }

    func testSourceEncodingIsBackwardCompatible() throws {
        var s = DictionarySync()
        s.set("cloud code", "Claude Code", at: 1)
        s.set("Atmus", "Atmos", at: 2, origin: .auto)
        let text = String(decoding: s.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("MANUAL"), "手動的不寫欄位：舊版讀到的檔案跟以前一樣")
        XCTAssertEqual(text.components(separatedBy: #""source" : "AUTO""#).count - 1, 1)
        let back = try DictionarySync.decode(s.encoded())
        XCTAssertEqual(back.entries["Atmus"]?.source, .auto)
        XCTAssertEqual(back.entries["cloud code"]?.source, .manual)
        XCTAssertEqual(back, s)
        let legacy = try DictionarySync.decode(Data(#"{"format":"utuvo-type-dictionary","version":1,"entries":{"a":{"at":1,"output":"A"}}}"#.utf8))
        XCTAssertEqual(legacy.entries["a"], DictionarySync.Entry(output: "A", at: 1), "舊檔沒有來源＝手動")
        XCTAssertEqual(legacy.entries["a"]?.source, .manual)
    }

    /// 同 Kotlin DictionarySourceTest 的四條規則。
    func testSetOriginRulesMatchKotlin() {
        var d = DictionarySync()
        d.set("台梗", "抬槓", at: 100, origin: .auto)
        XCTAssertEqual(d.source(of: "台梗"), .auto, "新詞被自動學到 → 自動")
        d.set("台梗", "抬槓", at: 200, origin: .auto)
        XCTAssertEqual(d.source(of: "台梗"), .auto, "本來就是自動的再學到 → 還是自動")

        var m = DictionarySync()
        m.set("台梗", "抬槓", at: 100)
        m.set("台梗", "抬槓", at: 200, origin: .auto)
        XCTAssertEqual(m.source(of: "台梗"), .manual, "手動的詞被自動學到 → 維持手動")
        XCTAssertEqual(m.entries["台梗"]?.at, 200)

        d.set("台梗", "抬頭", at: 300, origin: .manual)
        XCTAssertEqual(d.source(of: "台梗"), .manual, "使用者手動覆蓋 → 手動")
        d.remove("台梗", at: 400)
        XCTAssertNil(d.source(of: "台梗"), "刪掉了就沒有來源")
        d.set("台梗", "抬槓", at: 500, origin: .auto)
        XCTAssertEqual(d.source(of: "台梗"), .auto, "刪掉後重新學到 → 自動")
        XCTAssertEqual(DictionarySync.Source.parse("AUTO"), .auto)
        XCTAssertEqual(DictionarySync.Source.parse(nil), .manual)
        XCTAssertEqual(DictionarySync.Source.parse("auto"), .manual, "同 Kotlin：只認大寫 AUTO")
    }

    func testMergeKeepsTheWinnersSource() {
        var mac = DictionarySync(); mac.set("Atmus", "Atmos", at: 1)
        var android = DictionarySync(); android.set("Atmus", "Atmos", at: 5, origin: .auto)
        XCTAssertEqual(mac.merged(with: android).source(of: "Atmus"), .auto)
        XCTAssertEqual(android.merged(with: mac).source(of: "Atmus"), .auto)
    }

    func testDictionaryTabsFilterBySource() {
        let entries: [(source: String, output: String)] = [("Atmus", "Atmos"), ("pik", "Pik"), ("UTUVO", "UTUVO")]
        let auto: Set<String> = ["Atmus", "UTUVO"]
        XCTAssertEqual(DictionarySync.filter(entries, tab: .all, autoTerms: auto, query: "").map(\.source), ["Atmus", "pik", "UTUVO"])
        XCTAssertEqual(DictionarySync.filter(entries, tab: .auto, autoTerms: auto, query: "").map(\.source), ["Atmus", "UTUVO"])
        XCTAssertEqual(DictionarySync.filter(entries, tab: .manual, autoTerms: auto, query: "").map(\.source), ["pik"])
        XCTAssertEqual(DictionarySync.filter(entries, tab: .auto, autoTerms: auto, query: "atmos").map(\.source), ["Atmus"],
                       "分頁＋搜尋一起")
        XCTAssertEqual(DictionarySync.filter(entries, tab: .manual, autoTerms: [], query: "").count, 3, "沒有標記＝全部算手動")
    }

    // MARK: - 2026-10-22 修補（verifier mac-learning2）：只差來源時合併結果不看順序

    /// 舊版用戶端把 AUTO 讀成手動（不認得 source 欄位）再寫回 iCloud：同時間、同寫法、只差來源。
    /// 以前 a.merged(b) 跟 b.merged(a) 結果不同，兩台機器互相覆寫 iCloud 停不下來。現在手動贏（使用者的詞不會被降成自動）。
    func testMergeIsCommutativeWhenOnlyTheSourceDiffers() {
        var auto = DictionarySync(); auto.set("UTUVO", "", at: 1000, origin: .auto)
        var manual = DictionarySync(); manual.entries["UTUVO"] = .init(output: "UTUVO", at: 1000)
        XCTAssertEqual(auto.merged(with: manual), manual.merged(with: auto))
        XCTAssertEqual(auto.merged(with: manual).source(of: "UTUVO"), .manual)
        XCTAssertEqual(manual.merged(with: auto).source(of: "UTUVO"), .manual)

        var autoGone = DictionarySync(); autoGone.entries["x"] = .init(output: nil, at: 5, source: .auto)
        var manualGone = DictionarySync(); manualGone.entries["x"] = .init(output: nil, at: 5)
        XCTAssertEqual(autoGone.merged(with: manualGone), manualGone.merged(with: autoGone), "墓碑也一樣")
        XCTAssertEqual(autoGone.merged(with: manualGone).entries["x"]?.source, .manual)
    }
}
