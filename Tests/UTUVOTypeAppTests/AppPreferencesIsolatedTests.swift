import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

@MainActor
final class AppPreferencesIsolatedTests: XCTestCase {
    func testDefaultsAndStorageAreInjected() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.addDictionaryTerm(source: "fixture", output: "Fixture")
        XCTAssertEqual(AppPreferences(isolation: context).dictionary["fixture"], "Fixture")
        XCTAssertEqual(preferences.applicationSupportDirectory, context.applicationSupportDirectory)
        XCTAssertEqual(preferences.logDirectory, context.logDirectory)
        XCTAssertFalse(preferences.cleanupEnabled)
        // asr-vocab-1（2026-10-22）：內建 ai、tw 包跟 iOS／Android 一樣預設開；catalog 六包照舊預設全關。
        XCTAssertEqual(preferences.enabledVocabularyPackIDs, BuiltInVocabulary.defaultOnIDs)
        XCTAssertTrue(preferences.enabledVocabularyPackIDs.isDisjoint(with: VocabularyCatalog.Catalog.knownIDs))
        DictionaryCloud.start(preferences) // Must return before constructing a live store.
    }
    func testTeardownOwnsOnlyUniqueChild() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = parent.appendingPathComponent("sentinel")
        try Data("fixture".utf8).write(to: sentinel)
        let a = try IsolatedContext.make(baseDirectory: parent)
        let b = try IsolatedContext.make(baseDirectory: parent); defer { b.tearDown() }
        XCTAssertNotEqual(a.suiteName, b.suiteName)
        a.tearDown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.applicationSupportDirectory.path))
    }
}
