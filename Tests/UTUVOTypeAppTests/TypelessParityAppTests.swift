import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// 2026-10-13 對齊 Typeless（App 端）：使用數據累計、字典建議、插入後定位。
@MainActor
final class TypelessParityAppTests: XCTestCase {
    func testUsageStatsCountEachRecordOnceAndPersist() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let id = UUID()
        prefs.appendHistory(HistoryRecord(id: id, rawTranscript: "嗯你好", output: "你好", duration: 2, mode: .smart))
        // 背景整理換字是同一筆：不再算一次
        prefs.appendHistory(HistoryRecord(id: id, rawTranscript: "嗯你好", output: "你好呀", duration: 2, mode: .smart))
        prefs.appendHistory(HistoryRecord(rawTranscript: "問", output: "很長很長的回答", duration: 1, mode: .smart),
                            countsTowardStats: false)
        XCTAssertEqual(prefs.usageStats.totalWords, 2)
        XCTAssertEqual(prefs.usageStats.totalSessions, 1)
        XCTAssertEqual(AppPreferences(isolation: context).usageStats.totalWords, 2, "重開還在")
        prefs.clearHistory()
        XCTAssertEqual(prefs.usageStats.totalWords, 2, "清歷史不清數據")
    }

    func testSuggestionsSkipKnownIgnoredAndDuplicatesThenAcceptAddsToDictionary() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        prefs.addDictionaryTerm(source: "除值", output: "儲值")
        let a = EditTracker.Correction(from: "元山", to: "圓山")
        let b = EditTracker.Correction(from: "除值", to: "儲值")
        let c = EditTracker.Correction(from: "Atmus", to: "Atmos")
        prefs.addSuggestions([a, b, c, a])
        XCTAssertEqual(prefs.dictionarySuggestions, [c, a], "已在字典的不建議、重複的只留一筆、新的在前")
        prefs.ignoreSuggestion(c)
        prefs.addSuggestions([c])
        XCTAssertEqual(prefs.dictionarySuggestions, [a], "忽略過的不再出現")
        prefs.acceptSuggestion(a)
        XCTAssertEqual(prefs.dictionary["元山"], "圓山")
        XCTAssertTrue(prefs.dictionarySuggestions.isEmpty)
        prefs.learnFromEdits = false
        prefs.addSuggestions([EditTracker.Correction(from: "x1", to: "y1")])
        XCTAssertTrue(prefs.dictionarySuggestions.isEmpty, "關掉就不收建議")
    }

    func testLocateFindsEditedInsertionByAnchors() {
        let inserted = "我搭到元山站以後再換車"
        let field = "前面的字。我搭到圓山站以後再換車。後面的字"
        XCTAssertEqual(EditWatcher.locate(inserted, in: field), "我搭到圓山站以後再換車")
        XCTAssertNil(EditWatcher.locate(inserted, in: "完全不相干的另一段文字"), "找不到錨點就放棄")
        XCTAssertNil(EditWatcher.locate(inserted, in: "我搭到" + String(repeating: "很", count: 60) + "以後再換車"), "長度差太多不比對")
        // luna-review r1：同欄位後面另有一段相似文字時，分不出是哪段就放棄，不能學到 quick → quirk
        XCTAssertNil(EditWatcher.locate("the quick brown", in: "the quack brown and the quirk brown"))
        XCTAssertEqual(EditWatcher.locate("the quick brown", in: "the quack brown and the dog"), "the quack brown")
        // luna-review r2：前面那段比較像原文，但剛貼的是後面那段（游標在結尾）→ 要挑後面那段，不能學到錯的
        let value = "the quack brown fox the quock brawn fox"
        XCTAssertEqual(EditWatcher.locate("the quick brown fox", in: value, expectedEnd: value.utf16.count), "the quock brawn fox")
        XCTAssertEqual(EditWatcher.locate("the quick brown fox", in: value, expectedEnd: 19), "the quack brown fox")
        XCTAssertNil(EditWatcher.locate("the quick brown fox", in: value, expectedEnd: 200), "游標離所有候選都太遠就放棄")
    }
}
