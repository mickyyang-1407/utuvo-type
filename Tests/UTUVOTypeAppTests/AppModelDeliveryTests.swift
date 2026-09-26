import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class CapturedFixture: DictationDestination {
    var supportsCorrection = true
    var valid = true
    var text = ""
    var replacements = 0
    func insert(_ text: String) async -> Bool { guard valid else { return false }; self.text = text; return true }
    func replaceInsertedText(with text: String) -> Bool {
        guard valid else { return false }; self.text = text; replacements += 1; return true
    }
    func invalidate() { valid = false }
}

@MainActor
final class AppModelDeliveryTests: XCTestCase {
    private func model(_ context: IsolatedContext, target: CapturedFixture) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        preferences.appendTrailingSpace = true
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in target }
        model.cleanupRunner = { _, _ in
            try? await Task.sleep(for: .milliseconds(80))
            return "合成測試文字。"
        }
        return model
    }
    func testCaptureOccursAtStartAndImmediateHistoryPrecedesCleanup() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: CapturedFixture())
        var captures = 0
        model.captureDestination = { _ in captures += 1; return target }
        model.startRecording(mode: .smart) // Isolated start captures, then stops before microphone.
        XCTAssertEqual(captures, 1)
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertEqual(target.replacements, 0)
        XCTAssertFalse(target.text.isEmpty)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(target.replacements, 1)
        XCTAssertEqual(target.text, "合成測試文字。 ")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字。")
        model.cancelProcessing()
    }

    func testSmartCleanupReceivesRawStutterWhileImmediateTextIsNormalized() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: CapturedFixture())
        model.captureDestination = { _ in target }
        let raw = "我、我想明天先確認資料，明天先確認資料"
        model.cleanupRunner = { received, _ in
            XCTAssertEqual(received, raw)
            return "我想明天先確認資料"
        }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(raw)
        XCTAssertFalse(target.text.contains("我、我"))
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(target.text, "我想明天先確認資料 ")
        model.cancelProcessing()
    }

    func testLocalSmartFormatterRefinesAfterImmediateInsertion() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = false
        preferences.backend = .local
        preferences.localEditorCommand = "fixture-local-editor"
        let target = CapturedFixture()
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in target }
        model.cleanupRunner = { _, _ in XCTFail("Local Smart must not call the cloud cleanup provider"); return nil }
        model.localBackgroundRunner = { text, _, _ in
            try? await Task.sleep(for: .milliseconds(80))
            return text.replacingOccurrences(of: "然後", with: "接著")
        }

        let transcript = "我們明天中午先確認大家都收到資料，然後下午三點再開會"
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(transcript)
        XCTAssertTrue(target.text.contains("然後"), "Deterministic text should be inserted before the editor responds")
        await model.waitForBackgroundCleanup()

        XCTAssertEqual(target.replacements, 1)
        XCTAssertTrue(target.text.contains("接著"))
        XCTAssertEqual(model.preferences.historyRecords.first?.output, target.text.trimmingCharacters(in: .whitespaces))
        model.cancelProcessing()
    }

    func testSlowLocalFormatterCannotHoldBackgroundCompletionOrReplaceLate() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = false
        preferences.backend = .local
        preferences.localEditorCommand = "fixture-local-editor"
        let target = CapturedFixture()
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in target }
        model.localBackgroundRunner = { text, _, _ in
            await withCheckedContinuation { continuation in
                // Ignore task cancellation like a formatter stuck in blocking IO.
                DispatchQueue.global().asyncAfter(deadline: .now() + 4.8) {
                    continuation.resume(returning: text.replacingOccurrences(of: "然後", with: "接著"))
                }
            }
        }

        let transcript = "我們明天中午先確認大家都收到資料，然後下午三點再開會"
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(transcript)
        XCTAssertTrue(target.text.contains("然後"))
        let start = Date()
        await model.waitForBackgroundCleanup()
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5)
        XCTAssertEqual(target.replacements, 0)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(target.replacements, 0, "Late formatter output must not overwrite the user's field")
        XCTAssertTrue(target.text.contains("然後"))
        model.cancelProcessing()
    }

    func testCancelAfterImmediateOutputCannotOverwriteHistory() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: CapturedFixture())
        model.captureDestination = { _ in target }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        let delivered = model.preferences.historyRecords.first?.output
        model.cancelProcessing() // isProcessing is already false.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(target.replacements, 0)
        XCTAssertEqual(model.preferences.historyRecords.first?.output, delivered)
    }
    func testNewSessionOrUserEditPermanentlyRejectsOldCleanup() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: CapturedFixture())
        model.captureDestination = { _ in target }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        target.text += "使用者新增"
        target.valid = false
        model.startRecording(mode: .smart)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(target.replacements, 0)
        XCTAssertTrue(target.text.hasSuffix("使用者新增"))
        model.cancelProcessing()
    }
    func testUnsupportedCorrectionKeepsDeliveredText() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(); target.supportsCorrection = false
        let model = model(context, target: target)
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(target.replacements, 0)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
    }
    func testUnsupportedLanguagesUseActualOneShotFormatterBranch() async throws {
        for language in TranscriptionLanguage.allCases where ![.traditionalChinese, .english].contains(language) {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let target = CapturedFixture(), model = model(context, target: CapturedFixture())
            model.preferences.transcriptionLanguage = language
            model.captureDestination = { _ in target }
            model.cleanupRunner = { _, _ in XCTFail("Unsupported language must not start background cleanup"); return nil }
            var formattingCalls = 0
            let original = String(repeating: "這是用來驗證語言路由的合成段落", count: 8)
            let formatted = original + "。"
            model.legacyFormatterRunner = { prompt in
                formattingCalls += 1
                XCTAssertTrue(prompt.contains(original))
                return formatted
            }
            model.startRecording(mode: .smart)
            await model.completeSyntheticDictation(original)
            await model.waitForBackgroundCleanup()
            XCTAssertEqual(formattingCalls, 1, language.rawValue)
            XCTAssertEqual(model.lastOutput, formatted, language.rawValue)
            XCTAssertEqual(model.preferences.historyRecords.first?.output, formatted)
            XCTAssertEqual(target.text, "", "One-shot branch must not use the background AX destination")
            XCTAssertEqual(target.replacements, 0)
            model.cancelProcessing()
        }
    }
    /// 2026-09-24 實機（苑涵 0.1.5）：Smart 在不支援 AX 替換的欄位整筆消失（不貼、不寫歷史）。
    /// 新規格：跟 Fast 一樣改走剪貼簿貼一次；貼之前先在時限內整理；一律寫歷史並記原因。
    func testFailedCaptureOrInsertionFallsBackToOnePasteWithHistory() async throws {
        for captureFails in [true, false] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let target = CapturedFixture(); target.valid = false
            let model = model(context, target: target)
            model.captureDestination = { _ in captureFails ? nil : target }
            let cleanupCalls = LockedCounter()
            model.cleanupRunner = { _, _ in cleanupCalls.increment(); return "合成測試文字。" }
            model.legacyFormatterRunner = { _ in XCTFail("Fallback must not use the one-shot formatter branch"); return "" }
            var events: [String] = []
            model.onDeliveryEvent = { events.append($0) }
            model.startRecording(mode: .smart)
            await model.completeSyntheticDictation("合成測試文字")
            await model.waitForBackgroundCleanup()
            XCTAssertEqual(cleanupCalls.value, 1)
            XCTAssertEqual(model.lastOutput, "合成測試文字。")
            XCTAssertEqual(model.preferences.historyRecords.count, 1, "每一筆都要寫進歷史")
            XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字。")
            XCTAssertNotNil(model.preferences.historyRecords.first?.note)
            XCTAssertEqual(target.text, "", "不能 AX 插入的目的地一個字都不寫（改走剪貼簿）")
            XCTAssertFalse(events.contains("inserted"))
            XCTAssertEqual(events.last, "fallback")
            model.cancelProcessing()
        }
    }

    /// 2026-09-24 實機：被取消的卸載計時器立刻醒來殺掉 ASR server（每次辨識完都重載模型）。
    func testRescheduledUnloadStopsRuntimeOnceAfterDelayOnly() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = model(context, target: CapturedFixture())
        let stops = LockedCounter()
        model.stopRuntime = { stops.increment() }
        model.unloadDelayOverride = .milliseconds(300)
        model.preferences.unloadPolicy = .afterFiveMinutes
        for _ in 0..<5 {                       // 連續 5 次辨識完成，每次都重排卸載
            model.scheduleRuntimeUnload()
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(stops.value, 0, "被取消的計時器不能提早卸載")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(stops.value, 1, "閒置滿時限後只卸載一次")
    }

    /// 2026-09-24 實機（苑涵）：講長句時想下一句，0.9 秒靜音就停止聆聽。預設不自動結束；開了也要安靜 3 秒。
    func testLongPausesDoNotEndDictationByDefault() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        XCTAssertFalse(AppPreferences(isolation: context).voiceActivityDetection)
        XCTAssertGreaterThanOrEqual(AudioCaptureSession.autoStopSilenceSeconds, 3)
    }

    /// 金鑰錯／斷網：整理回 nil，照樣出字（本機整理版）並寫歷史＋原因。
    func testFallbackStillDeliversWhenCleanupFails() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = model(context, target: CapturedFixture())
        model.captureDestination = { _ in nil }
        model.cleanupRunner = { _, _ in nil }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertEqual(model.lastOutput, "合成測試文字")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字")
        let note = model.preferences.historyRecords.first?.note ?? ""
        XCTAssertTrue(note.contains("智慧整理") || note.contains("Smart cleanup"), note)
        model.cancelProcessing()
    }
    func testLanguageEligibilitySharesCleanupSupportPredicate() {
        for language in TranscriptionLanguage.allCases {
            let expected = language == .traditionalChinese || language == .english
            XCTAssertEqual(SmartCleanup.supportsLanguage(language.rawValue), expected)
            XCTAssertEqual(AppModel.backgroundEligible(mode: .smart, translation: .off, autoSubmit: .off,
                enabled: true, language: language.rawValue), expected)
        }
    }
    func testEligibilityPreservesEditDeepTranslationAndSubmitSemantics() async {
        XCTAssertTrue(AppModel.backgroundEligible(mode: .smart, translation: .off, autoSubmit: .off, enabled: true, language: "zh-TW"))
        for mode: FormatterMode in [.fast, .deep, .editSelection] {
            XCTAssertFalse(AppModel.backgroundEligible(mode: mode, translation: .off, autoSubmit: .off, enabled: true, language: "zh-TW"))
        }
        XCTAssertFalse(AppModel.backgroundEligible(mode: .smart, translation: .english, autoSubmit: .off, enabled: true, language: "zh-TW"))
        XCTAssertFalse(AppModel.backgroundEligible(mode: .smart, translation: .off, autoSubmit: .returnKey, enabled: true, language: "zh-TW"))
    }
}
