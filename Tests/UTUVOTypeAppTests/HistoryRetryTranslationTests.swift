import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// FX-4（2026-10-22）：翻譯過的聽寫，紀錄要記住翻成什麼語言；從歷史重試照樣翻譯，翻不出來時不拿原文蓋掉之前的譯文。
/// 全部在隔離模式跑：翻譯只走注入的系統翻譯，不開麥克風、不碰剪貼簿、Keychain、網路。
@MainActor
final class HistoryRetryTranslationTests: XCTestCase {

    // MARK: - 歷史檔格式：translation 是新欄位，解碼跟 status 一樣寬鬆

    private func json(_ records: [HistoryRecord]) throws -> String {
        String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    }

    func testTranslationRoundTripsAndOffIsNotWritten() throws {
        let translated = HistoryRecord(rawTranscript: "合成測試文字", output: "Synthetic test text.", duration: 2,
                                       mode: .smart, translation: .english)
        let encoded = try json([translated])
        XCTAssertTrue(encoded.contains("\"translation\":\"en\""), encoded)
        XCTAssertEqual(try JSONDecoder().decode([HistoryRecord].self, from: Data(encoded.utf8)), [translated])
        // 沒翻譯的紀錄寫回去不帶這欄：格式跟以前一樣，舊版 App 讀得回來。
        let plain = HistoryRecord(rawTranscript: "合成測試文字", output: "合成測試文字", duration: 2, mode: .smart)
        XCTAssertFalse(try json([plain]).contains("translation"))
    }

    func testOldRecordWithoutTranslationDecodesAsOff() throws {
        let old = """
        [{"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0001","date":782000000,"rawTranscript":"合成測試文字",\
        "output":"合成測試文字。","duration":3.2,"mode":"smart","isStarred":false}]
        """
        let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(old.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].translation, "舊紀錄沒有這欄＝沒翻譯")
    }

    /// 之後版本寫了這版不認得的語言（或型別不對）：那一筆當沒翻譯，其他欄位和整份歷史照樣讀得出來。
    func testUnknownTranslationDecodesAsOffAndKeepsTheWholeHistory() throws {
        let history = """
        [{"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0001","date":782000000,"rawTranscript":"合成測試文字",\
        "output":"","duration":3.2,"mode":"smart","isStarred":true,"status":"failed","note":"合成原因",\
        "translation":"tlh"},\
        {"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0002","date":782000100,"rawTranscript":"第二筆",\
        "output":"二","duration":1,"mode":"fast","isStarred":false,"translation":42},\
        {"id":"6F1C2C1E-8B53-4E39-9A4B-1D2B7C1E0003","date":782000200,"rawTranscript":"第三筆",\
        "output":"テスト","duration":1,"mode":"smart","isStarred":false,"translation":"ja"}]
        """
        let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(history.utf8))
        XCTAssertEqual(records.count, 3, "一筆壞掉不能讓整份歷史讀不出來")
        XCTAssertNil(records[0].translation)
        XCTAssertEqual(records[0].status, .failed, "其他欄位照樣讀")
        XCTAssertEqual(records[0].note, "合成原因")
        XCTAssertTrue(records[0].isStarred)
        XCTAssertNil(records[1].translation, "型別不對也當沒翻譯")
        XCTAssertEqual(records[1].output, "二")
        XCTAssertEqual(records[2].translation, .japanese)
    }

    /// 只有聽寫記翻譯目標；關閉＝不記；Edit Selection 的紀錄照舊不記（不能從歷史重試）。
    func testStoredTranslationPolicy() {
        XCTAssertEqual(HistoryRecord.storedTranslation(.english, mode: .smart), .english)
        XCTAssertEqual(HistoryRecord.storedTranslation(.japanese, mode: .fast), .japanese)
        XCTAssertEqual(HistoryRecord.storedTranslation(.french, mode: .deep), .french)
        XCTAssertNil(HistoryRecord.storedTranslation(.off, mode: .smart))
        XCTAssertNil(HistoryRecord.storedTranslation(.english, mode: .editSelection))
    }

    // MARK: - 寫紀錄：成功、辨識失敗、取消都記翻譯目標

    private final class Calls {
        var log: [String] = []
    }

    /// 智慧整理關著（不讀 Keychain、不送雲端）、本機 editor 沒設定：翻譯只走注入的系統翻譯。
    /// 句尾語氣適用的語言（繁中），才看得出譯文有沒有被誤套句尾語氣。
    private func makeModel(_ context: IsolatedContext, translated: String?) -> (AppModel, Calls) {
        let preferences = AppPreferences(isolation: context)
        preferences.mode = .fast
        preferences.pushToTalkEnabled = false
        preferences.cleanupEnabled = false
        preferences.localEditorCommand = ""
        preferences.transcriptionLanguage = .traditionalChinese
        let model = AppModel(preferences: preferences)
        let calls = Calls()
        model.systemTranslationRunner = { text, _, target in calls.log.append("system:\(target):\(text)"); return translated }
        model.localEditorTranslationRunner = { _, _ in calls.log.append("editor"); return nil }
        model.cleanupKeyLookup = { _ in calls.log.append("keychain"); return "" }
        return (model, calls)
    }

    private func temporaryRecording() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utuvo-type-test-\(UUID().uuidString).caf")
        try Data("synthetic-audio".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 按翻譯變體的熱鍵開始（隔離模式：停在麥克風前），然後從「錄音已停、辨識中」跑正式收尾。
    private func translatedCapture(_ model: AppModel, _ target: TranslationTarget,
                                   transcribe: @MainActor () async -> (text: String, error: Error?)) async throws {
        model.shortcutPressed(translation: target)
        await model.completeSyntheticCapture(audioURL: try temporaryRecording(), duration: 2, transcribe: transcribe)
    }

    func testTranslatedDictationRecordsItsTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: "Synthetic test text.")
        try await translatedCapture(model, .english) { ("合成測試文字", nil) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertNil(record.status)
        XCTAssertEqual(record.output, "Synthetic test text.")
        XCTAssertEqual(record.translation, .english)
    }

    func testUntranslatedDictationRecordsNoTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "never")
        try await translatedCapture(model, .off) { ("合成測試文字", nil) }
        try await translatedCapture(model, .off) { ("", URLError(.timedOut)) }
        XCTAssertEqual(model.preferences.historyRecords.count, 2)
        XCTAssertEqual(model.preferences.historyRecords.map(\.translation), [nil, nil])
        XCTAssertEqual(calls.log, [], "沒翻譯不碰翻譯")
    }

    /// 翻譯聽寫辨識失敗（或靜音）之後，從選單直接開始的下一次錄音（`startRecording(mode:)`，不經熱鍵）
    /// 不能沿用上一次的翻譯目標。
    func testFailedTranslatedCaptureLeavesNoTargetForTheNextMenuRecording() async throws {
        for silent in [false, true] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let (model, calls) = makeModel(context, translated: "never")
            model.shortcutPressed(translation: .english)
            await model.completeSyntheticCapture(audioURL: try temporaryRecording(), duration: 2, soundsSilent: silent) {
                ("", silent ? nil : URLError(.timedOut))
            }
            model.startRecording(mode: .fast)
            await model.completeSyntheticCapture(audioURL: try temporaryRecording(), duration: 2) { ("合成測試文字", nil) }
            XCTAssertEqual(calls.log, [], silent ? "靜音之後" : "辨識失敗之後")
            let latest = try XCTUnwrap(model.preferences.historyRecords.first(where: { $0.status == nil }))
            XCTAssertNil(latest.translation)
            XCTAssertFalse(latest.output.contains("never"))
        }
    }

    func testRecognitionFailureDuringTranslatedDictationRecordsTheTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: "never")
        try await translatedCapture(model, .japanese) { ("", URLError(.notConnectedToInternet)) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.translation, .japanese)
    }

    /// 取消會把當下的翻譯目標歸零：紀錄要用停止那一刻記下的。
    func testCancelDuringRecognitionRecordsTheTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: "never")
        try await translatedCapture(model, .english) {
            model.cancelProcessing()
            return ("合成測試文字", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.translation, .english)
    }

    func testCancelBeforeAnyTranscriptRecordsTheTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: "never")
        try await translatedCapture(model, .english) {
            model.cancelProcessing()
            return ("", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.isAudioOnly)
        XCTAssertEqual(record.translation, .english)
    }

    /// 翻譯途中（雲端「整理 → 翻譯」的整理那步）取消：補寫的「已取消」紀錄也記翻譯目標。
    func testCancelDuringTranslationRecordsTheTarget() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "never")
        model.preferences.cleanupEnabled = true
        model.cleanupKeyLookup = { _ in "synthetic-key" }
        model.cleanupRunner = { _, _ in
            await model.cancelProcessing()
            return "合成測試文字。"
        }
        model.cloudTranslationRunner = { _, _, _ in XCTFail("取消後不能再送翻譯"); return "never" }
        try await translatedCapture(model, .english) { ("合成測試文字", nil) }
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.rawTranscript, "合成測試文字")
        XCTAssertEqual(record.translation, .english)
        XCTAssertFalse(calls.log.contains { $0.hasPrefix("system") })
    }

    // MARK: - 重試：照存下來的目標翻譯

    private func seeded(_ preferences: AppPreferences, output: String, translation: TranslationTarget?) -> HistoryRecord {
        let record = HistoryRecord(rawTranscript: "合成測試文字", output: output, duration: 3, mode: .smart,
                                   appName: "Notes", bundleIdentifier: "com.apple.Notes",
                                   audioPath: "/nonexistent/synthetic.caf", translation: translation)
        preferences.appendHistory(record)
        return record
    }

    func testRetryOfTranslatedEntryTranslatesAgainInPlace() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "合成テスト。")
        let record = seeded(model.preferences, output: "古い翻訳。", translation: .japanese)
        let statsBefore = model.preferences.usageStats
        model.retryHistory(record)
        await model.waitForHistoryRetry()

        XCTAssertEqual(calls.log, ["system:ja:合成測試文字"], "存下來的目標要送到翻譯，不是原文輸出")
        let records = model.preferences.historyRecords
        XCTAssertEqual(records.count, 1, "不新增一筆")
        let updated = try XCTUnwrap(records.first)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.output, "合成テスト。", "譯文不套句尾語氣（句號不拿掉）")
        XCTAssertNil(updated.note)
        XCTAssertEqual(updated.translation, .japanese, "再重試一次也照樣翻譯")
        XCTAssertEqual(model.isolatedClipboard, "合成テスト。")
        XCTAssertEqual(model.preferences.usageStats, statsBefore, "使用數據不再算一次")
        XCTAssertEqual(model.preferences.mode, .fast, "不改預設模式")
        XCTAssertFalse(model.isProcessing)
    }

    /// 沒翻譯的紀錄重試照舊：不碰翻譯，套句尾語氣。
    func testRetryOfUntranslatedEntryNeverTranslates() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "never")
        let record = seeded(model.preferences, output: "舊的輸出", translation: nil)
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(calls.log, [])
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(updated.output, "合成測試文字")
        XCTAssertNil(updated.translation)
        XCTAssertNil(updated.note)
    }

    /// 辨識失敗的翻譯聽寫：重試＝重新辨識，再照存下來的目標翻譯；完成後算一次使用數據（跟沒翻譯的一樣）。
    func testRetranscribeRetryOfFailedTranslatedEntryTranslates() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "Synthetic test text.")
        try await translatedCapture(model, .english) { ("", URLError(.timedOut)) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        model.recordingTranscriber = { _ in ("合成測試文字", nil) }
        model.retryHistory(record)
        await model.waitForHistoryRetry()

        XCTAssertEqual(calls.log, ["system:en:合成測試文字"])
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertNil(updated.status)
        XCTAssertEqual(updated.rawTranscript, "合成測試文字")
        XCTAssertEqual(updated.output, "Synthetic test text.")
        XCTAssertEqual(updated.translation, .english)
        XCTAssertEqual(model.preferences.usageStats.totalSessions, 1)
    }

    /// 取消的翻譯聽寫有逐字稿：重試＝重新整理，照存下來的目標翻譯。
    func testReformatRetryOfCancelledTranslatedEntryTranslates() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: "Synthetic test text.")
        try await translatedCapture(model, .english) {
            model.cancelProcessing()
            return ("合成測試文字", nil)
        }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        var transcriberCalls = 0
        model.recordingTranscriber = { _ in transcriberCalls += 1; return ("不該用到", nil) }
        model.retryHistory(record)
        await model.waitForHistoryRetry()
        XCTAssertEqual(transcriberCalls, 0)
        XCTAssertEqual(calls.log, ["system:en:合成測試文字"])
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertNil(updated.status)
        XCTAssertEqual(updated.output, "Synthetic test text.")
    }

    // MARK: - 重試時翻譯失敗

    /// 一般聽寫翻不出來時寫的原因（同一個設定、另一份隔離資料），重試要用同一句。
    private func normalPathNote() async throws -> String {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: nil)
        await model.completeSyntheticDictation("合成測試文字", translation: .english)
        let note = try XCTUnwrap(model.preferences.historyRecords.first?.note)
        XCTAssertTrue(note.contains(model.preferences.tr("翻譯未完成", "Translation did not complete")), note)
        return note
    }

    /// 之前翻好的譯文不能被這次的原文蓋掉：留著舊的輸出，原因照一般路徑的寫法。
    func testTranslationFailureOnRetryKeepsThePreviousTranslation() async throws {
        let expectedNote = try await normalPathNote()
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, calls) = makeModel(context, translated: nil)
        let record = seeded(model.preferences, output: "Previous translation.", translation: .english)
        let statsBefore = model.preferences.usageStats
        model.retryHistory(record)
        await model.waitForHistoryRetry()

        XCTAssertEqual(calls.log, ["system:en:合成測試文字"], "有試著翻")
        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertEqual(updated.output, "Previous translation.", "舊的譯文留著，不換成原文")
        let keptNote = expectedNote
            .replacingOccurrences(of: "已輸出原文", with: "保留這筆原本的譯文")
            .replacingOccurrences(of: "the original text was pasted", with: "this entry's previous translation was kept")
        XCTAssertNotEqual(keptNote, expectedNote, "一般路徑的原因有「已輸出原文」這段")
        XCTAssertEqual(updated.note, keptNote, "原因同一般路徑，結尾照實講保留了舊譯文（重試沒有輸出原文）")
        XCTAssertEqual(updated.translation, .english)
        XCTAssertEqual(model.preferences.usageStats, statsBefore)
        XCTAssertFalse(model.isProcessing)
    }

    /// 這筆本來就沒有輸出（辨識失敗的紀錄）：跟一般路徑一樣，輸出原文並寫原因。
    func testTranslationFailureOnRetryOfEntryWithoutOutputWritesTextAndNote() async throws {
        let expectedNote = try await normalPathNote()
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let (model, _) = makeModel(context, translated: nil)
        try await translatedCapture(model, .english) { ("", URLError(.timedOut)) }
        let record = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(record.output, "")
        model.recordingTranscriber = { _ in ("合成測試文字", nil) }
        model.retryHistory(record)
        await model.waitForHistoryRetry()

        let updated = try XCTUnwrap(model.preferences.historyRecords.first)
        XCTAssertEqual(updated.id, record.id)
        XCTAssertNil(updated.status)
        XCTAssertEqual(updated.output, "合成測試文字", "沒有舊結果可留：輸出原文")
        XCTAssertEqual(updated.note, expectedNote)
        XCTAssertEqual(updated.translation, .english)
    }
}
