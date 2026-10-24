import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

@MainActor
private final class MemoryCloud: DictionaryCloudStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data, forKey key: String) { values[key] = data }
}

@MainActor
final class DictionarySyncIsolatedTests: XCTestCase {
    func testProductionCloudAddUpdateDeleteAndExport() async throws {
        let a = try IsolatedContext.make(); defer { a.tearDown() }
        let b = try IsolatedContext.make(); defer { b.tearDown() }
        let pa = AppPreferences(isolation: a), pb = AppPreferences(isolation: b)
        let cloud = MemoryCloud()
        pa.addDictionaryTerm(source: "fixture", output: "First")
        DictionaryCloud.sync(pa, store: cloud); DictionaryCloud.sync(pb, store: cloud)
        XCTAssertEqual(pb.dictionary["fixture"], "First")
        try await Task.sleep(for: .milliseconds(5))
        pb.addDictionaryTerm(source: "fixture", output: "Second")
        DictionaryCloud.sync(pb, store: cloud); DictionaryCloud.sync(pa, store: cloud)
        XCTAssertEqual(pa.dictionary["fixture"], "Second")
        try await Task.sleep(for: .milliseconds(5))
        pa.removeDictionaryTerm(source: "fixture")
        DictionaryCloud.sync(pa, store: cloud); DictionaryCloud.sync(pb, store: cloud)
        XCTAssertNil(pb.dictionary["fixture"])
        let exported = try DictionarySync.decode(pb.exportDictionaryData())
        XCTAssertNotNil(exported.entries["fixture"])
        XCTAssertNil(exported.entries["fixture"]?.output)
        XCTAssertEqual(cloud.values.keys.sorted(), [DictionaryCloud.key])
    }
    func testExportsOnlyDictionaryAndNewerImportWins() async throws {
        let a = try IsolatedContext.make(); defer { a.tearDown() }
        let b = try IsolatedContext.make(); defer { b.tearDown() }
        let pa = AppPreferences(isolation: a), pb = AppPreferences(isolation: b)
        pa.addDictionaryTerm(source: "fixture", output: "Old")
        _ = pb.mergeDictionary(try DictionarySync.decode(pa.exportDictionaryData()))
        try await Task.sleep(for: .milliseconds(5))
        pb.addDictionaryTerm(source: "fixture", output: "New")
        _ = pa.mergeDictionary(try DictionarySync.decode(pb.exportDictionaryData()))
        XCTAssertEqual(pa.dictionary["fixture"], "New")
        a.userDefaults.set("synthetic-secret-must-not-export", forKey: "fixture.key")
        pa.appendHistory(HistoryRecord(rawTranscript: "private-fixture-history", output: "fixture-output", duration: 0,
            mode: .smart, appName: nil, bundleIdentifier: nil))
        let text = String(decoding: pa.exportDictionaryData(), as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-secret")); XCTAssertFalse(text.contains("private-fixture-history"))
    }

    // MARK: - app-shell-2：清空全部先確認、單字移除可以復原

    func testClearAllPromptCountsTermsAndCancelKeepsPhoneWords() throws {
        let mac = try IsolatedContext.make(); defer { mac.tearDown() }
        let phone = try IsolatedContext.make(); defer { phone.tearDown() }
        let pm = AppPreferences(isolation: mac), pp = AppPreferences(isolation: phone)
        let cloud = MemoryCloud()
        for w in ["Atmos", "Pro Tools", "DAMI music", "UTUVO", "Tonmeister"] { pp.addDictionaryTerm(source: w, output: "") }
        DictionaryCloud.sync(pp, store: cloud); DictionaryCloud.sync(pm, store: cloud)
        XCTAssertEqual(pm.dictionary.count, 5)

        // 按「清空全部」只產生確認文案；使用者按取消＝什麼都不呼叫。
        let prompt = try XCTUnwrap(pm.dictionaryClearPrompt())
        XCTAssertEqual(prompt.count, 5, "確認文案的筆數＝實際筆數")
        XCTAssertTrue(prompt.title.contains("5"))
        XCTAssertTrue(prompt.message.contains("iCloud") && prompt.message.contains("iPhone"))
        XCTAssertTrue(prompt.message.contains("無法復原") || prompt.message.contains("can't be undone"))
        DictionaryCloud.sync(pm, store: cloud)
        XCTAssertEqual(try DictionarySync.decode(XCTUnwrap(cloud.values[DictionaryCloud.key])).live.count, 5, "取消後 iCloud 仍是 5 個詞")

        // 確認刪除（設定頁的「全部刪除」按鈕做的就是這兩行）。
        pm.resetDictionaryToEmpty(); DictionaryCloud.sync(pm, store: cloud)
        XCTAssertEqual(try DictionarySync.decode(XCTUnwrap(cloud.values[DictionaryCloud.key])).live.count, 0)
        DictionaryCloud.sync(pp, store: cloud)
        XCTAssertTrue(pp.dictionary.isEmpty, "同一個 iCloud 的 iPhone 也刪光——確認文案講的就是這件事")
        XCTAssertNil(pm.dictionaryClearPrompt(), "空字典不用確認")
    }

    func testRemovedTermCanBeUndoneAcrossDevices() async throws {
        let mac = try IsolatedContext.make(); defer { mac.tearDown() }
        let phone = try IsolatedContext.make(); defer { phone.tearDown() }
        let pm = AppPreferences(isolation: mac), pp = AppPreferences(isolation: phone)
        let cloud = MemoryCloud()
        pm.addDictionaryTerm(source: "cloud code", output: "Claude Code")
        pm.dictionaryJSON = #"{"Atmos":"","cloud code":"Claude Code"}"#   // 從 iPhone 來的「詞彙」模式（輸出留空）
        DictionaryCloud.sync(pm, store: cloud); DictionaryCloud.sync(pp, store: cloud)
        try await Task.sleep(for: .milliseconds(5))
        pm.removeDictionaryTerm(source: "Atmos"); DictionaryCloud.sync(pm, store: cloud); DictionaryCloud.sync(pp, store: cloud)
        XCTAssertNil(pp.dictionary["Atmos"])
        try await Task.sleep(for: .milliseconds(5))
        pm.restoreDictionaryTerm(source: "Atmos", output: "")
        DictionaryCloud.sync(pm, store: cloud); DictionaryCloud.sync(pp, store: cloud)
        XCTAssertEqual(pm.dictionary, ["Atmos": "", "cloud code": "Claude Code"], "原樣放回，輸出留空也保留")
        XCTAssertEqual(pp.dictionary["Atmos"], "", "復原蓋過刪除紀錄，iPhone 也拿回來")
    }

    // MARK: - app-shell-6：純詞表匯入先問、不蓋掉既有寫法；JSON 字典檔照舊

    func testWordListImportAsksFirstAndKeepsExistingOutputs() throws {
        let ctx = try IsolatedContext.make(); defer { ctx.tearDown() }
        let prefs = AppPreferences(isolation: ctx)
        prefs.addDictionaryTerm(source: "Atmos", output: "Dolby Atmos")
        let data = Data("\u{FEFF}Atmos\r\nPro Tools\n\n\"DAMI music\",note\nAtmos\n".utf8)
        guard case .confirmWords(let prompt) = try prefs.prepareDictionaryImport(data, fileName: "words.csv") else {
            return XCTFail("一行一詞的檔案要先確認")
        }
        XCTAssertEqual(prompt.words, ["Atmos", "Pro Tools", "DAMI music"])
        XCTAssertEqual(prompt.newCount, 2)
        XCTAssertTrue(prompt.title.contains("3") && prompt.title.contains("words.csv"))
        XCTAssertEqual(prefs.dictionary, ["Atmos": "Dolby Atmos"], "按「加入」之前字典不動")

        XCTAssertEqual(prefs.addDictionaryWords(prompt.words), 2)
        XCTAssertEqual(prefs.dictionary, ["Atmos": "Dolby Atmos", "Pro Tools": "Pro Tools", "DAMI music": "DAMI music"],
                       "已經有的詞不被蓋掉；新詞寫法＝詞本身")
        XCTAssertNotNil(prefs.dictionarySync.entries["Pro Tools"]?.at)
    }

    func testJSONImportPathIsUnchangedAndBrokenJSONIsNotAWordList() throws {
        let a = try IsolatedContext.make(); defer { a.tearDown() }
        let b = try IsolatedContext.make(); defer { b.tearDown() }
        let pa = AppPreferences(isolation: a), pb = AppPreferences(isolation: b)
        pa.addDictionaryTerm(source: "fixture", output: "Value")
        XCTAssertEqual(try pb.prepareDictionaryImport(pa.exportDictionaryData(), fileName: "dict.json"), .merged(1))
        XCTAssertEqual(pb.dictionary, ["fixture": "Value"])

        let broken = Data("{\n  \"entries\" : {\n    \"Atmos\" : {\n".utf8)
        XCTAssertThrowsError(try pb.prepareDictionaryImport(broken, fileName: "broken.json")) {
            XCTAssertEqual($0 as? DictionarySync.DecodeError, .notDictionaryFile)
        }
        XCTAssertThrowsError(try pb.prepareDictionaryImport(Data(" \n\n".utf8), fileName: "empty.txt")) {
            XCTAssertEqual($0 as? DictionarySync.WordListError, .noWords)
        }
        XCTAssertEqual(pb.dictionary, ["fixture": "Value"], "失敗的匯入不動字典")
    }
}
