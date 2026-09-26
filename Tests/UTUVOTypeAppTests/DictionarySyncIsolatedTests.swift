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
}
