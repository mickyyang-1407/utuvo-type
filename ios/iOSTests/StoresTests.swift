import XCTest
@testable import UTUVOTypeiOS

/// IOS3：儲存層覆蓋（v1 完全零測試）。
final class StoresTests: XCTestCase {

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - HistoryStore

    func testAppendThenLoadRoundTrip() {
        let store = HistoryStore(directory: makeTempDirectory())
        store.append(DictationRecord(raw: "原始逐字稿", cleaned: "清理後文字"))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.raw, "原始逐字稿")
        XCTAssertEqual(loaded.first?.cleaned, "清理後文字")
        XCTAssertEqual(loaded.first?.source, .app, "沒指定來源時預設是 app")
    }

    func testNewestRecordComesFirst() {
        let store = HistoryStore(directory: makeTempDirectory())
        store.append(DictationRecord(raw: "第一筆", cleaned: "第一筆"))
        store.append(DictationRecord(raw: "第二筆", cleaned: "第二筆"))

        XCTAssertEqual(store.load().first?.raw, "第二筆", "最新的要排在最前面")
    }

    func testKeyboardSourceSurvivesRoundTrip() {
        let store = HistoryStore(directory: makeTempDirectory())
        store.append(DictationRecord(raw: "鍵盤打的", cleaned: "鍵盤打的", source: .keyboard))
        XCTAssertEqual(store.load().first?.source, .keyboard)
    }

    func testAppendTruncatesAtMaxRecords() {
        let store = HistoryStore(directory: makeTempDirectory())
        for index in 0..<(HistoryStore.maxRecords + 25) {
            store.append(DictationRecord(raw: "第\(index)筆", cleaned: "第\(index)筆"))
        }

        let loaded = store.load()
        XCTAssertEqual(loaded.count, HistoryStore.maxRecords, "上限應為 \(HistoryStore.maxRecords) 筆")
        XCTAssertEqual(loaded.first?.raw, "第\(HistoryStore.maxRecords + 24)筆", "留下的要是最新的")
        XCTAssertEqual(loaded.last?.raw, "第25筆", "被截掉的要是最舊的")
    }

    func testLoadOnEmptyStoreReturnsNoRecords() {
        XCTAssertTrue(HistoryStore(directory: makeTempDirectory()).load().isEmpty)
    }

    func testLoadOnCorruptFileReturnsNoRecordsInsteadOfCrashing() {
        let dir = makeTempDirectory()
        try! Data("這不是 JSON".utf8).write(to: dir.appendingPathComponent("history.json"))
        XCTAssertTrue(HistoryStore(directory: dir).load().isEmpty)
    }

    // MARK: - DictionaryStore

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "utuvo.type.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // teardown 只捕獲 suite 名稱（String 是 Sendable）；UserDefaults 本身不是。
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAddAndRemoveTerm() {
        let store = DictionaryStore(defaults: makeIsolatedDefaults())
        store.addTerm(source: "pik", output: "Pik")
        XCTAssertEqual(store.dictionary["pik"], "Pik")

        store.removeTerm(source: "pik")
        XCTAssertNil(store.dictionary["pik"])
    }

    func testAddTermWithEmptyOutputKeepsSourceWord() {
        let store = DictionaryStore(defaults: makeIsolatedDefaults())
        store.addTerm(source: "Atmos", output: "")
        XCTAssertEqual(store.dictionary["Atmos"], "Atmos", "空的替換值應保留原詞，不是存成空字串")
    }

    func testBadJSONDecodesToEmptyDictionary() {
        let defaults = makeIsolatedDefaults()
        defaults.set("{ 這不是合法 JSON", forKey: "utuvo.type.ios.dictionary")
        XCTAssertTrue(DictionaryStore(defaults: defaults).dictionary.isEmpty)
    }

    func testDictionaryFeedsTextPipeline() {
        let store = DictionaryStore(defaults: makeIsolatedDefaults())
        store.addTerm(source: "pik", output: "Pik")
        let (output, _) = TextPipeline(dictionary: store.dictionary).clean("我在pik，很順")
        XCTAssertTrue(output.contains("Pik"), "字典應透過 store 一路生效到管線，實際：\(output)")
    }
}
