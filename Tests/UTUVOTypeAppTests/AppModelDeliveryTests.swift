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
    var isCurrentForInsertion: Bool { valid }
    var insertions = 0
    var rejectsInsertion = false
    var text = ""
    var replacements = 0
    func insert(_ text: String) async -> Bool { guard valid, !rejectsInsertion else { return false }; insertions += 1; self.text = text; return true }
    func replaceInsertedText(with text: String) -> Bool {
        guard valid else { return false }; self.text = text; replacements += 1; return true
    }
    func invalidate() { valid = false }
    /// 模擬 Electron：AX 寫入回報失敗，但字晚一點才出現在欄位裡。
    var lateText: String?
    func textPresent(_ text: String) -> Bool { lateText == text }
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
    /// 2026-10-19 Typeless 對打：上一句還在轉錄時按熱鍵原本被靜默吃掉；現在排隊，處理完自動開錄，再按一次取消。
    func testShortcutDuringProcessingQueuesInsteadOfDropping() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.pushToTalkEnabled = false
        let model = AppModel(preferences: preferences)
        model.setProcessingForTesting(true)
        model.shortcutPressed()
        XCTAssertEqual(model.pendingStart, .off, "處理中按的開始要排隊")
        XCTAssertFalse(model.isRecording)
        model.shortcutPressed()
        XCTAssertNil(model.pendingStart, "再按一次＝取消排隊")
        model.shortcutPressed()
        model.setProcessingForTesting(false)
        XCTAssertNil(model.pendingStart, "處理完就把排隊的開始送出")
    }

    func testCaptureAtStartAndHistoryFollowSingleFinalInsertion() async throws {
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
        XCTAssertEqual(target.replacements, 0)
        // 2026-10-02：最後一句不加句號（SentenceMood.finish）——整理版換上去時也一樣。
        XCTAssertEqual(target.text, "合成測試文字 ")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字")
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

    /// asr-vocab-v2：字典裡輸出寫法留空的詞（從 iPhone／Android 同步來的「詞彙」模式）也要拿來修英文專名。
    func testVocabularyModeDictionaryWordFixesLatinMishearing() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: target)
        model.captureDestination = { _ in target }
        model.preferences.dictionaryJSON = #"{"Atmos":""}"#
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("我用 Atmus 混")
        XCTAssertEqual(target.replacements, 0, "先貼的是本機整理版")
        XCTAssertTrue(target.text.hasPrefix("我用 Atmos 混"), "got: \(target.text)")
        model.cancelProcessing()
    }

    func testLocalSmartFormatterFinishesBeforeSingleInsertion() async throws {
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
            return text.replacingOccurrences(of: "資料，然後", with: "資料；然後")
        }

        let transcript = "我們明天中午先確認大家都收到資料，然後下午三點再開會"
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(transcript)
        XCTAssertTrue(target.text.contains("然後"), "Deterministic text should be inserted before the editor responds")
        await model.waitForBackgroundCleanup()

        XCTAssertEqual(target.replacements, 0)
        XCTAssertTrue(target.text.contains("資料；然後"))
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
            // 2026-10-02：整理回來的「合成測試文字。」最後一句不加句號（SentenceMood.finish）。
            XCTAssertEqual(model.lastOutput, "合成測試文字")
            XCTAssertEqual(model.preferences.historyRecords.count, 1, "每一筆都要寫進歷史")
            XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字")
            XCTAssertNotNil(model.preferences.historyRecords.first?.note)
            XCTAssertEqual(target.text, "", "不能 AX 插入的目的地一個字都不寫（改走剪貼簿）")
            XCTAssertFalse(events.contains("inserted"))
            XCTAssertEqual(events.last, "undelivered")
            model.cancelProcessing()
        }
    }

    /// 2026-10-14 實機（Claude 桌面版）：AX 寫入回報失敗後改走剪貼簿；若字其實晚到，貼上前要發現、不能貼兩份。
    func testLateAXTextSkipsClipboardPaste() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(); target.valid = false
        target.lateText = "合成測試文字 "
        let model = model(context, target: target)
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(events.last, "undelivered", "目的地已失效不能再嘗試寫入")
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字", "歷史記實際送達的原句")
        model.cancelProcessing()
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
        let target = CapturedFixture()
        let model = model(context, target: target)
        model.cleanupRunner = { _, _ in nil }
        model.localBackgroundRunner = { _, _, _ in nil }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertEqual(model.lastOutput, "合成測試文字")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字")
        let note = model.preferences.historyRecords.first?.note ?? ""
        XCTAssertTrue(note.contains("智慧整理") || note.contains("Smart cleanup"), note)
        model.cancelProcessing()
    }
    func testPendingCleanupInsertsNothingThenOneFinalResultWithRawHistory() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: target)
        model.cleanupRunner = { raw, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return raw + "。"
        }
        model.startRecording(mode: .smart)
        let task = Task { await model.completeSyntheticDictation("合成測試文字") }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(target.insertions, 0)
        XCTAssertTrue(model.preferences.historyRecords.isEmpty)
        await task.value
        XCTAssertEqual(target.insertions, 1)
        XCTAssertEqual(target.replacements, 0)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
        XCTAssertEqual(model.preferences.historyRecords.first?.rawTranscript, "合成測試文字")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "合成測試文字")
    }

    func testCloudTimeoutLeavesIndependentLocalBudgetAndIgnoresLateCandidate() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: target)
        model.dictationBudgetForTesting = (0.03, 0.2)
        model.cleanupRunner = { _, _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    continuation.resume(returning: "合成測試文字")
                }
            }
        }
        model.localBackgroundRunner = { raw, _, _ in
            try? await Task.sleep(for: .milliseconds(60)); return raw + "。"
        }
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        XCTAssertTrue(events.contains("local-fallback"))
        XCTAssertEqual(target.insertions, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(target.insertions, 1)
        XCTAssertEqual(model.preferences.historyRecords.count, 1)
    }

    func testCancelOrChangedTargetDuringCleanupNeverInserts() async throws {
        for cancel in [true, false] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let target = CapturedFixture(), model = model(context, target: target)
            model.startRecording(mode: .smart)
            let task = Task { await model.completeSyntheticDictation("合成測試文字") }
            try await Task.sleep(for: .milliseconds(20))
            if cancel { model.cancelProcessing() } else { target.valid = false }
            await task.value
            XCTAssertEqual(target.insertions, 0)
            XCTAssertEqual(target.replacements, 0)
            XCTAssertEqual(model.preferences.historyRecords.count, cancel ? 0 : 1)
        }
    }

    func testCapturedClipboardDestinationWaitsAndSubmitsOnceWithHonestDiagnostic() async throws {
        for changeField in [true, false] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let preferences = AppPreferences(isolation: context)
            preferences.cleanupEnabled = true
            let model = AppModel(preferences: preferences)
            var field = "captured", submits: [String] = [], events: [String] = []
            let clipboard = CapturedClipboardDestination(isCurrent: { field == "captured" },
                submit: { submits.append($0) })
            model.captureDestination = { _ in clipboard }
            model.cleanupRunner = { raw, _ in
                try? await Task.sleep(for: .milliseconds(80)); return raw + "。"
            }
            model.onDeliveryEvent = { events.append($0) }
            model.startRecording(mode: .smart)
            let task = Task { await model.completeSyntheticDictation("合成測試文字") }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(submits.isEmpty)
            if changeField { field = "other" }
            await task.value
            XCTAssertEqual(submits.count, changeField ? 0 : 1)
            XCTAssertFalse(events.contains("delivered"), "Clipboard submission cannot prove host acceptance")
            XCTAssertEqual(events.contains("insertion-api-accepted"), !changeField)
            XCTAssertEqual(model.preferences.historyRecords.count, 1)
            let again = await clipboard.insert("遲到")
            XCTAssertFalse(again, "The captured clipboard destination is one-shot")
        }
    }

    func testRequestKeepsProviderDictionaryVariantAndTrailingSpaceSnapshot() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = CapturedFixture(), model = model(context, target: target)
        model.preferences.cleanupProvider = .groq
        model.preferences.dictionaryJSON = #"{"DAMI music":""}"#
        model.preferences.setLanguageVariant(.zhTW, for: .traditionalChinese)
        model.preferences.appendTrailingSpace = true
        model.cleanupRunner = { _, config in
            try? await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(config.provider, .groq)
            XCTAssertEqual(config.variant, .zhTW)
            XCTAssertEqual(config.personal, ["DAMI music": ""])
            return "我在 Darmy Music 工作。"
        }
        model.startRecording(mode: .smart)
        let task = Task { await model.completeSyntheticDictation("我在 Darmy Music 工作") }
        try await Task.sleep(for: .milliseconds(20))
        model.preferences.cleanupProvider = .claude
        model.preferences.dictionaryJSON = #"{"Darmy Music":"Other Company"}"#
        model.preferences.setLanguageVariant(.zhCN, for: .traditionalChinese)
        model.preferences.appendTrailingSpace = false
        await task.value
        XCTAssertEqual(target.text, "我在 DAMI music 工作 ")
        XCTAssertEqual(target.insertions, 1)
    }

    func testAXNoLandingUsesCapturedClipboardWithoutRerunningCleanupOrDuplicatingLateText() async throws {
        for outcome in ["no-landing", "late-landing", "changed"] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let target = CapturedFixture(); target.rejectsInsertion = true
            let model = model(context, target: target)
            var current = true, pastes: [String] = [], events: [String] = []
            let clipboard = CapturedClipboardDestination(isCurrent: { current }, submit: { pastes.append($0) })
            model.captureClipboardDestination = { _ in clipboard }
            let calls = LockedCounter()
            model.cleanupRunner = { raw, _ in
                calls.increment(); try? await Task.sleep(for: .milliseconds(80)); return raw + "。"
            }
            model.onDeliveryEvent = { events.append($0) }
            model.startRecording(mode: .smart)
            let task = Task { await model.completeSyntheticDictation("合成測試文字") }
            try await Task.sleep(for: .milliseconds(20))
            if outcome == "changed" { current = false; target.valid = false }
            if outcome == "late-landing" { target.lateText = "合成測試文字 " }
            await task.value
            XCTAssertEqual(calls.value, 1)
            XCTAssertEqual(pastes.count, outcome == "no-landing" ? 1 : 0)
            XCTAssertEqual(events.contains("delivered"), outcome == "late-landing")
            XCTAssertEqual(events.contains("insertion-api-accepted"), outcome == "no-landing")
            XCTAssertEqual(model.preferences.historyRecords.count, 1)
        }
    }

    func testThrowingCapturedClipboardReportsPasteFailureInsteadOfChangedDestination() async throws {
        enum PasteFixtureError: Error { case denied }
        for withAXAttempt in [false, true] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let preferences = AppPreferences(isolation: context)
            preferences.cleanupEnabled = true
            let model = AppModel(preferences: preferences)
            var submissions = 0, events: [String] = []
            let clipboard = CapturedClipboardDestination(isCurrent: { true }, submit: { _ in
                submissions += 1; throw PasteFixtureError.denied
            })
            let ax = CapturedFixture(); ax.rejectsInsertion = true
            model.captureDestination = { _ in
                if withAXAttempt { return ax }
                return clipboard
            }
            model.captureClipboardDestination = { _ in clipboard }
            model.cleanupRunner = { raw, _ in raw + "。" }
            model.onDeliveryEvent = { events.append($0) }
            model.startRecording(mode: .smart)
            await model.completeSyntheticDictation("合成測試文字")
            XCTAssertEqual(submissions, 1)
            XCTAssertTrue(events.contains("insertion-rejected"))
            XCTAssertFalse(events.contains("skipped-target-changed"))
            XCTAssertFalse(events.contains("delivered"))
            XCTAssertFalse(events.contains("insertion-api-accepted"))
            XCTAssertEqual(model.preferences.historyRecords.count, 1)
            let note = model.preferences.historyRecords.first?.note ?? ""
            XCTAssertTrue(note.contains("貼上失敗") || note.lowercased().contains("paste failed"), note)
            let status = model.statusMessage
            XCTAssertTrue(status.contains("貼上失敗") || status.lowercased().contains("paste failed"), status)
            XCTAssertFalse(note.contains("目的地已變更") || note.contains("destination changed"), note)
        }
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
