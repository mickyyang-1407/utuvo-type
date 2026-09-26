import XCTest
@testable import UTUVOTypeApp

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
        XCTAssertTrue(preferences.enabledVocabularyPackIDs.isEmpty)
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
