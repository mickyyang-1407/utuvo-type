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
}
