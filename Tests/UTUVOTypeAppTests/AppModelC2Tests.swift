import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var configs: [CleanupConfig] = []
    private var events: [String] = []
    func add(_ config: CleanupConfig) { lock.lock(); configs.append(config); lock.unlock() }
    func log(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    var all: [CleanupConfig] { lock.lock(); defer { lock.unlock() }; return configs }
    var order: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

@MainActor
private final class FixtureDestination: DictationDestination {
    var supportsCorrection = true
    var valid = true
    var text = ""
    func insert(_ text: String) async -> Bool { guard valid else { return false }; self.text = text; return true }
    func replaceInsertedText(with text: String) -> Bool { guard valid else { return false }; self.text = text; return true }
    func invalidate() { valid = false }
}

/// Ticket C2（2026-10-22）：Mac 的脈絡、模式與投遞。全部在隔離模式跑：不碰麥克風、剪貼簿、Keychain、網路。
@MainActor
final class AppModelC2Tests: XCTestCase {

    // MARK: - context-awareness-v1：脈絡在開始聽寫時抓，不是 ASR 結束後

    func testContextIsCapturedWhenDictationStartsNotAfterASR() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        preferences.includeSurroundingContext = true
        let model = AppModel(preferences: preferences)
        let destination = FixtureDestination()
        model.captureDestination = { _ in destination }
        let box = ConfigBox()
        model.cleanupRunner = { _, config in box.add(config); return nil }
        var reads: [String] = []
        model.captureContext = { _, _ in
            reads.append("A")
            return LimitedAppContext(appName: "Mail", surroundingText: "開始時的欄位哨兵", textAfterCursor: "游標後哨兵")
        }
        model.startRecording(mode: .smart)   // 隔離模式：抓目的地＋脈絡後就停在麥克風前
        // 講話中使用者換到別的分頁：之後才讀到的脈絡不能被用上。
        model.captureContext = { _, _ in
            reads.append("B")
            return LimitedAppContext(appName: "Safari", surroundingText: "別的地方")
        }
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()

        XCTAssertEqual(reads, ["A"], "脈絡只在開始時讀一次")
        let config = try XCTUnwrap(box.all.first, "背景整理要拿到脈絡")
        XCTAssertEqual(config.context.surroundingText, "開始時的欄位哨兵")
        XCTAssertEqual(config.context.textAfterCursor, "游標後哨兵")
        XCTAssertEqual(config.context.appName, "Mail")
        XCTAssertEqual(preferences.historyRecords.first?.appName, "Mail")
        model.cancelProcessing()
    }

    /// 不能拿上一次聽寫抓的脈絡：沒有經過開始流程（token 不同）就當下再讀。
    func testStaleCapturedContextIsNotReused() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        preferences.includeSurroundingContext = true
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in FixtureDestination() }
        let box = ConfigBox()
        model.cleanupRunner = { _, config in box.add(config); return nil }
        model.captureContext = { _, _ in LimitedAppContext(surroundingText: "第一次") }
        model.startRecording(mode: .smart)
        model.cancelProcessing()               // 換了 token
        model.captureContext = { _, _ in LimitedAppContext(surroundingText: "當下") }
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(box.all.first?.context.surroundingText, "當下")
        model.cancelProcessing()
    }

    // MARK: - modes-1：語音翻譯的路線

    private func translationModel(_ context: IsolatedContext, cleanupEnabled: Bool, key: String,
                                  editorCommand: String = "") -> (AppModel, ConfigBox) {
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = cleanupEnabled
        preferences.localEditorCommand = editorCommand
        let model = AppModel(preferences: preferences)
        let box = ConfigBox()
        model.cleanupKeyLookup = { _ in box.log("keychain"); return key }
        model.cleanupRunner = { raw, _ in box.log("cleanup:\(raw)"); return "合成測試文字。" }
        model.cloudTranslationRunner = { system, text, route in
            box.log("cloud:\(text)")
            XCTAssertEqual(system, TranslatePrompt.system(targetZh: "英文", targetEn: "English"))
            XCTAssertEqual(route.key, key)
            return "```\nSynthetic test text.\n```"
        }
        model.systemTranslationRunner = { _, _, _ in box.log("system"); return nil }
        return (model, box)
    }

    func testCloudTranslationCleansFirstThenTranslatesWithSharedPrompt() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: true, key: "synthetic-key")
        await model.completeSyntheticDictation("合成測試文字", translation: .english)
        XCTAssertEqual(box.order, ["keychain", "cleanup:合成測試文字", "cloud:合成測試文字。"],
                       "先整理（同一道把關），再用共用提示詞翻譯")
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.output, "Synthetic test text.", "譯文不過整理把關；code fence 拿掉")
        XCTAssertNil(record.note)
    }

    func testCleanupOffNeverReadsKeyOrSendsToCloud() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: false, key: "synthetic-key")
        await model.completeSyntheticDictation("合成測試文字", translation: .english)
        XCTAssertFalse(box.order.contains("keychain"), "智慧整理沒開：不讀 Keychain")
        XCTAssertFalse(box.order.contains { $0.hasPrefix("cloud") }, "智慧整理沒開：不送雲端")
        XCTAssertEqual(box.order, ["system"])
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.output, "合成測試文字", "翻不了就輸出原文")
        let p = model.preferences
        XCTAssertTrue(record.note?.contains(p.tr("翻譯未完成", "Translation did not complete")) == true, "歷史那筆要寫原因")
        XCTAssertTrue(record.note?.contains(p.tr("智慧整理", "Smart Cleanup")) == true, "告訴使用者怎麼開")
    }

    func testNoKeyFallsBackToSystemThenLocalEditor() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: true, key: "", editorCommand: "fixture-editor")
        var editorTarget: TranslationTarget?
        model.localEditorTranslationRunner = { _, target in editorTarget = target; box.log("editor"); return "Local text" }
        await model.completeSyntheticDictation("合成測試文字", translation: .english)
        XCTAssertEqual(box.order.filter { !$0.hasPrefix("cleanup") }, ["keychain", "system", "editor"])
        XCTAssertEqual(editorTarget, .english)
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "Local text")
        XCTAssertNil(model.preferences.historyRecords.first?.note)
    }

    func testSystemTranslatorIsUsedBeforeLocalEditor() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: false, key: "", editorCommand: "fixture-editor")
        var request: (String, String, String)?
        model.systemTranslationRunner = { text, source, target in request = (text, source, target); box.log("system"); return "Bonjour" }
        model.localEditorTranslationRunner = { _, _ in box.log("editor"); return "never" }
        model.preferences.transcriptionLanguage = .traditionalChinese
        await model.completeSyntheticDictation("合成測試文字", translation: .french)
        XCTAssertEqual(box.order, ["system"])
        XCTAssertEqual(request?.1, "zh-TW")
        XCTAssertEqual(request?.2, "fr")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "Bonjour")
    }

    func testCloudFailureFallsThroughAndKeepsTheCleanedText() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: true, key: "synthetic-key")
        model.cloudTranslationRunner = { _, _, _ in box.log("cloud-fail"); throw URLError(.timedOut) }
        await model.completeSyntheticDictation("合成測試文字", translation: .english)
        XCTAssertEqual(box.order, ["keychain", "cleanup:合成測試文字", "cloud-fail", "system"])
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.output, "合成測試文字。", "雲端翻不了：輸出整理過的原文")
        XCTAssertTrue(record.note?.contains(model.preferences.tr("翻譯未完成", "Translation did not complete")) == true)
    }

    func testTranslationOffNeverTouchesTranslators() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, box) = translationModel(context, cleanupEnabled: false, key: "synthetic-key")
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertEqual(box.order, [])
        XCTAssertNil(model.preferences.historyRecords.first?.note)
    }

    // MARK: - app-shell-v1：歷史重試就地更新

    private func seededHistory(_ preferences: AppPreferences, note: String? = nil) -> HistoryRecord {
        let record = HistoryRecord(rawTranscript: "合成測試文字", output: "舊的輸出", duration: 3, mode: .smart,
                                   appName: "Notes", bundleIdentifier: "com.apple.Notes",
                                   audioPath: "/nonexistent/synthetic.caf", note: note)
        preferences.appendHistory(record)
        return record
    }

    private func assertRetriedInPlace(_ model: AppModel, _ record: HistoryRecord, statsBefore: UsageStats,
                                      events: [String], file: StaticString = #filePath, line: UInt = #line) {
        let records = model.preferences.historyRecords
        XCTAssertEqual(records.count, 1, "不新增一筆", file: file, line: line)
        XCTAssertEqual(records.first?.id, record.id, file: file, line: line)
        XCTAssertNotEqual(records.first?.output, "舊的輸出", "結果寫回同一筆", file: file, line: line)
        XCTAssertEqual(records.first?.audioPath, record.audioPath, file: file, line: line)
        XCTAssertEqual(records.first?.rawTranscript, record.rawTranscript, file: file, line: line)
        XCTAssertEqual(records.first?.date, record.date, file: file, line: line)
        XCTAssertEqual(model.preferences.usageStats, statsBefore, "使用數據不再算一次", file: file, line: line)
        XCTAssertEqual(model.preferences.mode, .fast, "不偷改預設模式", file: file, line: line)
        XCTAssertEqual(model.isolatedClipboard, records.first?.output, "結果放剪貼簿", file: file, line: line)
        XCTAssertEqual(model.retriedHistoryID, record.id, file: file, line: line)
        XCTAssertEqual(events.filter { $0 == "retry-updated" }.count, 1, file: file, line: line)
        XCTAssertFalse(events.contains("inserted"), "不貼到最前面的 App（設定頁按重試時那是 Type 自己）", file: file, line: line)
        XCTAssertFalse(model.isProcessing, file: file, line: line)
    }

    func testRetryUpdatesSameEntryWithoutStatsOrModeChange() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.mode = .fast
        let model = AppModel(preferences: preferences)
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }
        let record = seededHistory(preferences)
        let statsBefore = preferences.usageStats
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        assertRetriedInPlace(model, record, statsBefore: statsBefore, events: events)
        XCTAssertEqual(preferences.historyRecords.first?.output, "合成測試文字")
    }

    /// 智慧整理開著時走背景整理那條路：重試沒有欄位可以先插入，整理完一次寫回同一筆。
    func testRetryWithSmartCleanupAlsoUpdatesInPlace() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.mode = .fast
        preferences.cleanupEnabled = true
        let model = AppModel(preferences: preferences)
        var captures = 0
        model.captureDestination = { _ in captures += 1; return FixtureDestination() }
        model.cleanupRunner = { _, _ in "合成測試文字。" }
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }
        let record = seededHistory(preferences)
        let statsBefore = preferences.usageStats
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        assertRetriedInPlace(model, record, statsBefore: statsBefore, events: events)
        XCTAssertEqual(captures, 0, "重試不抓目的地")
        XCTAssertNil(preferences.historyRecords.first?.note, "重試不寫「已用剪貼簿貼上」")
    }

    func testAskAnythingEntryIsNotRetried() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        let model = AppModel(preferences: preferences)
        let record = seededHistory(preferences, note: HistoryRecord.askAnythingNote)
        XCTAssertTrue(record.isAskAnything)
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(preferences.historyRecords, [record], "Ask 的指令不能被當聽寫重跑")
        XCTAssertTrue(model.statusMessage.contains(preferences.tr("不能重試", "can't be retried")))
        XCTAssertFalse(model.isProcessing)
        XCTAssertNil(model.isolatedClipboard)
    }

    func testOrdinaryHistoryEntryIsNotAskAnything() {
        XCTAssertFalse(HistoryRecord(rawTranscript: "a", output: "b", duration: 1, mode: .smart).isAskAnything)
        XCTAssertFalse(HistoryRecord(rawTranscript: "a", output: "b", duration: 1, mode: .smart,
                                     note: "智慧整理沒有在時限內完成").isAskAnything)
    }

    /// 重新整理最後一段是新的一筆（貼到目前游標），但同一段話已經算過使用數據。
    func testReprocessAddsEntryButDoesNotCountStatsTwice() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        let model = AppModel(preferences: preferences)
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertEqual(preferences.historyRecords.count, 1)
        let statsAfterFirst = preferences.usageStats
        XCTAssertNotEqual(statsAfterFirst, UsageStats(), "第一次聽寫要算")
        model.reprocessLastResult()
        for _ in 0..<200 where model.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(preferences.historyRecords.count, 2)
        XCTAssertEqual(preferences.usageStats, statsAfterFirst)
    }
}
