import AppKit
import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func log(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 有「游標前文字」的目的地（context-awareness-2）。`textBeforeCursor` 在舊版只是這個 fixture 自己的屬性——
/// AppModel 不會讀它，所以舊版跑這些測試是執行期失敗（插入的字沒有前綴），不是編譯失敗。
@MainActor
private final class ContinuationFixture: DictationDestination {
    var supportsCorrection = true
    var valid = true
    var textBeforeCursor: String?
    /// 預設每個 fixture 都是「同一個欄位」、位置不知道（審查 10-22 加：接續只在同一個欄位）。
    var fieldIdentity: AnyHashable?
    var cursorLocation: Int?
    private(set) var inserted: [String] = []
    private(set) var replacements: [String] = []
    init(before: String?, field: AnyHashable? = "notes-body", location: Int? = nil) {
        textBeforeCursor = before; fieldIdentity = field; cursorLocation = location
    }
    func insert(_ text: String) async -> Bool { guard valid else { return false }; inserted.append(text); return true }
    func replaceInsertedText(with text: String) -> Bool {
        guard valid else { return false }; replacements.append(text); return true
    }
    func invalidate() { valid = false }
}

// MARK: - context-awareness-2：接續上一段

@MainActor
final class ContinuationPrefixAppTests: XCTestCase {
    private func smartModel(_ context: IsolatedContext, language: TranscriptionLanguage = .traditionalChinese,
                            trailingSpace: Bool = false) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        preferences.appendTrailingSpace = trailingSpace
        preferences.transcriptionLanguage = language
        let model = AppModel(preferences: preferences)
        // 整理服務回原句：背景替換一定會發生，看替換內容有沒有帶同一個前綴。
        model.cleanupRunner = { raw, _ in raw }
        return model
    }

    private func dictate(_ model: AppModel, into target: ContinuationFixture, _ text: String,
                         mode: FormatterMode = .smart, verifyPending: Bool = false) async {
        model.captureDestination = { _ in target }
        let originalRunner = model.cleanupRunner
        if verifyPending {
            model.cleanupRunner = { raw, config in
                try? await Task.sleep(for: .milliseconds(60))
                return await originalRunner(raw, config)
            }
        }
        model.startRecording(mode: mode)
        let historyCount = model.preferences.historyRecords.count
        let task = Task { await model.completeSyntheticDictation(text) }
        if verifyPending {
            try? await Task.sleep(for: .milliseconds(20))
            XCTAssertTrue(target.inserted.isEmpty, "整理未完成前不插入")
            XCTAssertEqual(model.preferences.historyRecords.count, historyCount, "未交付前不寫 final history")
        }
        await task.value
        await model.waitForBackgroundCleanup()
        if verifyPending {
            XCTAssertEqual(target.inserted.count, 1, "最終文字只插入一次")
            XCTAssertTrue(target.replacements.isEmpty, "不再背景覆寫")
            XCTAssertEqual(model.preferences.historyRecords.count, historyCount + 1)
            model.cleanupRunner = originalRunner
        }
    }

    /// 第三輪審查（10-22）改了期望值：原本補「。」，新規則中文接中文什麼都不補（插入與背景替換都一樣）。
    func testChineseContinuationInsertsNothingForInsertAndReplacement() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context)
        let first = ContinuationFixture(before: "")
        await dictate(model, into: first, "我到了")
        let previous = model.lastOutput
        XCTAssertEqual(first.inserted, [previous], "第一段沒有可接的，不加前綴")

        let second = ContinuationFixture(before: "訊息：" + previous)
        await dictate(model, into: second, "你在哪裡", verifyPending: true)
        let output = model.lastOutput
        XCTAssertFalse(output.hasPrefix("。"), "最後結果只記聽寫內容")
        XCTAssertEqual(second.inserted, [output], "游標前就是上一段結尾：中文接中文不補")
        XCTAssertTrue(second.replacements.isEmpty, "只有最終插入，沒有背景替換")
        XCTAssertFalse(model.preferences.historyRecords.contains { $0.output.hasPrefix("。") }, "歷史不含補的句號")
        model.cancelProcessing()
    }

    func testTrailingSpaceMeansNoPeriod() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context, trailingSpace: true)
        await dictate(model, into: ContinuationFixture(before: ""), "我到了")
        let previous = model.lastOutput
        let second = ContinuationFixture(before: previous + " ")
        await dictate(model, into: second, "你在哪裡")
        XCTAssertEqual(second.inserted, [model.lastOutput + " "], "結尾空白已經是分隔（caveat a）")
        model.cancelProcessing()
    }

    func testEnglishContinuationGetsASpace() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context, language: .english)
        await dictate(model, into: ContinuationFixture(before: ""), "I am here")
        let previous = model.lastOutput
        let second = ContinuationFixture(before: "Note: " + previous)
        await dictate(model, into: second, "where are you", verifyPending: true)
        XCTAssertEqual(second.inserted, [" " + model.lastOutput])
        XCTAssertTrue(second.replacements.isEmpty, "空白前綴跟最終文字一起插入一次")
        model.cancelProcessing()
    }

    func testNoPrefixWithoutCursorTextOrWhenCursorMoved() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context)
        await dictate(model, into: ContinuationFixture(before: ""), "我到了")
        let unknown = ContinuationFixture(before: nil)
        await dictate(model, into: unknown, "你在哪裡")
        XCTAssertEqual(unknown.inserted, [model.lastOutput], "讀不到游標前：不補")
        let moved = ContinuationFixture(before: "完全不同的內容")
        await dictate(model, into: moved, "等一下")
        XCTAssertEqual(moved.inserted, [model.lastOutput], "游標前不是上一段：不補")
        model.cancelProcessing()
    }

    func testClipboardPathUsesPrefixOnlyWithCapturedCursorText() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context)
        await dictate(model, into: ContinuationFixture(before: ""), "我到了")
        let previous = model.lastOutput
        model.preferences.cleanupEnabled = false
        await dictate(model, into: ContinuationFixture(before: previous), "你在哪裡", mode: .fast)
        // 第三輪審查（10-22）改了期望值：原本「。」＋結果；中文接中文不補。
        XCTAssertEqual(model.isolatedPastePayload, model.lastOutput, "Fast 模式剪貼簿貼上：中文接中文不補")
        // 非空前綴（拿掉的「，」）剪貼簿貼上也補。
        model.preferences.cleanupEnabled = true
        await dictate(model, into: ContinuationFixture(before: ""), "如果明天下雨的話，")
        let pause = model.lastOutput
        model.preferences.cleanupEnabled = false
        await dictate(model, into: ContinuationFixture(before: pause), "我們就改到室內", mode: .fast)
        XCTAssertEqual(model.isolatedPastePayload, "，" + model.lastOutput, "Fast 模式剪貼簿貼上也補回拿掉的逗號")

        // caveat (c)：沒有 AX 目的地（Electron 等）＝讀不到游標前，剪貼簿什麼都不加。
        model.captureDestination = { _ in nil }
        model.startRecording(mode: .fast)
        await model.completeSyntheticDictation("等一下")
        XCTAssertEqual(model.isolatedPastePayload, model.lastOutput)
        model.cancelProcessing()
    }

    /// 審查 10-22（problem 3）：「如果明天下雨的話，」講到一半停住，finish 拿掉「，」；下一段接上時以前補「。」。
    func testMidSentencePauseGetsTheCommaBackNotAPeriod() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context)
        let first = ContinuationFixture(before: "")
        await dictate(model, into: first, "如果明天下雨的話，")
        let previous = model.lastOutput
        XCTAssertEqual(previous, "如果明天下雨的話", "句尾吊著的逗號照樣拿掉（單獨一段時）")

        let second = ContinuationFixture(before: previous)
        await dictate(model, into: second, "我們就改到室內", verifyPending: true)
        let output = model.lastOutput
        XCTAssertEqual(second.inserted, ["，" + output], "補回的是拿掉的逗號，不是句號")
        XCTAssertTrue(second.replacements.isEmpty, "逗號前綴跟最終文字一起插入一次")

        // 第三輪審查（10-22）改了期望值：原本補「。」；沒有拿掉的逗號就什麼都不補。
        let third = ContinuationFixture(before: previous + "，" + output)
        await dictate(model, into: third, "大家記得帶傘")
        XCTAssertEqual(third.inserted, [model.lastOutput])
        model.cancelProcessing()
    }

    /// 第二輪審查 10-22：辨識沒給句尾標點、話還沒講完的兩段 Smart 聽寫，接起來不能變成「。」
    ///（「因為下雨。所以取消」「我想要。一杯咖啡」）。插入與背景替換用同一個前綴。
    /// 第三輪審查（10-22）改了期望值（原本「，」或「。」）：中文接中文一律什麼都不補；並加上審查員的探針。
    func testMidClauseContinuationGetsNothing() async throws {
        let cases: [(String, String, String)] = [
            ("因為下雨", "所以取消", ""), ("雖然很累", "但是很開心", ""), ("如果你有空", "我們就見面", ""),
            ("我想要", "一杯咖啡", ""), ("這是他說的話", "我記住了", ""), ("沒有如果", "只有結果", ""),
            ("我要", "一杯咖啡", ""), ("我的老闆", "明天要來", ""), ("請給我", "一杯水", ""), ("他在", "開會", ""),
            ("我們去", "台北", ""), ("把這個檔案", "寄給老闆", ""), ("你可以", "幫我買咖啡嗎", ""), ("我打算", "下週去日本", ""),
            ("明天早上", "我們去爬山", ""), ("我想用", "Pro Tools 混音", ""), ("這個專案的預算", "要再砍一半", ""),
            ("我想學", "才藝", ""), ("我住在", "就近的飯店", ""),
        ]
        for (first, second, prefix) in cases {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let model = smartModel(context)
            await dictate(model, into: ContinuationFixture(before: ""), first)
            let previous = model.lastOutput
            XCTAssertEqual(previous, first, "辨識結果本來就沒有句尾標點")
            let target = ContinuationFixture(before: previous)
            await dictate(model, into: target, second, verifyPending: true)
            XCTAssertEqual(target.inserted, [prefix + model.lastOutput], "\(first)＋\(second)")
            XCTAssertTrue(target.replacements.isEmpty, "\(first)＋\(second)（只插入一次）")
            model.cancelProcessing()
        }
    }

    /// 審查 10-22（problem 5）：同一個 App 的另一個欄位（另一則筆記）游標前剛好也是上一段的字，不能補。
    func testContinuationStaysInTheSameField() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = smartModel(context)
        await dictate(model, into: ContinuationFixture(before: "", field: "note-1", location: 0), "好")
        let previous = model.lastOutput
        XCTAssertEqual(previous, "好")

        let otherNote = ContinuationFixture(before: "他說" + previous, field: "note-2", location: 3)
        await dictate(model, into: otherNote, "我們走")
        XCTAssertEqual(otherNote.inserted, [model.lastOutput], "別的欄位：不補")

        // 回到 note-1，游標還停在「好」後面（位置 0＋1）：接得上。
        await dictate(model, into: ContinuationFixture(before: "", field: "note-1", location: 0), "好")
        let sameNote = ContinuationFixture(before: "好", field: "note-1", location: 1)
        await dictate(model, into: sameNote, "我們走")
        // 第三輪審查（10-22）改了期望值：原本「。」＋結果；中文接中文不補（同欄位規則用下面「好，」那段驗）。
        XCTAssertEqual(sameNote.inserted, [model.lastOutput])

        // 同一個欄位，但游標不在上一段結尾（同一個文字框換了內容、或點到別處）：不補。
        let moved = ContinuationFixture(before: "我們走", field: "note-1", location: 40)
        await dictate(model, into: moved, "等一下")
        XCTAssertEqual(moved.inserted, [model.lastOutput])

        // 欄位不知道（沒有 AX 目的地的那種）：不接續。
        await dictate(model, into: ContinuationFixture(before: "", field: nil), "我到了")
        let unknownField = ContinuationFixture(before: model.lastOutput, field: nil)
        await dictate(model, into: unknownField, "你在哪裡")
        XCTAssertEqual(unknownField.inserted, [model.lastOutput])

        // 同一套欄位規則，用有前綴的情況驗（拿掉的「，」）：別的欄位不補、同欄位同位置補、游標移走／欄位不知道不補。
        await dictate(model, into: ContinuationFixture(before: "", field: "note-1", location: 0), "好，")
        XCTAssertEqual(model.lastOutput, "好")
        let otherNoteComma = ContinuationFixture(before: "他說好", field: "note-2", location: 3)
        await dictate(model, into: otherNoteComma, "我們走")
        XCTAssertEqual(otherNoteComma.inserted, [model.lastOutput], "別的欄位：不補")
        await dictate(model, into: ContinuationFixture(before: "", field: "note-1", location: 0), "好，")
        let sameNoteComma = ContinuationFixture(before: "好", field: "note-1", location: 1)
        await dictate(model, into: sameNoteComma, "我們走")
        XCTAssertEqual(sameNoteComma.inserted, ["，" + model.lastOutput], "同欄位、游標沒動：補回拿掉的逗號")
        await dictate(model, into: ContinuationFixture(before: "", field: "note-1", location: 0), "好，")
        let movedComma = ContinuationFixture(before: "好", field: "note-1", location: 40)
        await dictate(model, into: movedComma, "等一下")
        XCTAssertEqual(movedComma.inserted, [model.lastOutput], "游標不在上一段結尾：不補")
        await dictate(model, into: ContinuationFixture(before: "", field: nil), "好，")
        let unknownFieldComma = ContinuationFixture(before: "好", field: nil)
        await dictate(model, into: unknownFieldComma, "我們走")
        XCTAssertEqual(unknownFieldComma.inserted, [model.lastOutput], "欄位不知道：不補")
        model.cancelProcessing()
    }

    /// 審查 10-22（problem 6）：游標前放寬讀「上一段＋8」只限上一段送進的那個 App 的那個欄位，其他地方照舊 32。
    func testWideCursorReadOnlyForThePreviousAppAndField() {
        let memory = AppModel.ContinuationMemory()
        memory.remember(pid: 42, text: String(repeating: "a", count: 4_000), droppedMark: "",
                        at: ContinuationFixture(before: "", field: "field-a", location: 0), payload: "")
        XCTAssertEqual(memory.beforeWindow(expectedPID: 42), 4_008)
        XCTAssertEqual(memory.beforeWindow(expectedPID: 7), 32, "別的 App：照舊 32")
        XCTAssertEqual(memory.beforeWindow(expectedPID: nil), 32, "不知道前景 App：32")
        XCTAssertEqual(AXAdapter.effectiveBeforeWindow(4_008, field: "field-a", previousField: memory.field), 4_008)
        XCTAssertEqual(AXAdapter.effectiveBeforeWindow(4_008, field: "field-b", previousField: memory.field), 32,
                       "同一個 App 的別的欄位：32")
        XCTAssertEqual(AXAdapter.effectiveBeforeWindow(4_008, field: "field-a", previousField: nil), 32)
        memory.forget()
        XCTAssertEqual(memory.beforeWindow(expectedPID: 42), 32)
    }

    func testCaptureWindowCoversPreviousOutput() {
        XCTAssertEqual(AXAdapter.beforeWindow(previous: nil), 32)
        XCTAssertEqual(AXAdapter.beforeWindow(previous: "我到了"), 32)
        XCTAssertEqual(AXAdapter.beforeWindow(previous: String(repeating: "字", count: 100)), 108)
        XCTAssertEqual(AXAdapter.beforeWindow(previous: String(repeating: "😀", count: 50)), 108, "UTF-16 計（emoji 佔 2）")
        XCTAssertEqual(AXAdapter.beforeWindow(previous: String(repeating: "a", count: 9_000)), 4_096, "有上限")
    }
}

// MARK: - modes-v1：Edit Selection 走使用者自己的雲端整理服務

@MainActor
final class EditSelectionCloudTests: XCTestCase {
    private func editModel(_ context: IsolatedContext, cleanupEnabled: Bool = true, postProcessing: Bool = true,
                           key: String = "synthetic-key", box: EventBox) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = cleanupEnabled
        preferences.postProcessingEnabled = postProcessing
        preferences.appLanguage = .traditionalChinese
        let model = AppModel(preferences: preferences)
        model.cleanupKeyLookup = { _ in box.log("keychain"); return key }
        model.captureContext = { _, _ in LimitedAppContext(appName: "Notes", selectedText: "原本的句子") }
        model.cloudEditRunner = { system, user, route in
            box.log("cloud")
            XCTAssertEqual(system, EditSelectionPrompt.system)
            XCTAssertEqual(user, EditSelectionPrompt.userMessage(original: "原本的句子", instruction: "改正式一點"))
            XCTAssertEqual(route.key, key)
            return "改好的正式版本"
        }
        model.legacyFormatterRunner = { _ in box.log("legacy"); return "舊路線結果" }
        model.onDeliveryEvent = { box.log("event:\($0)") }
        return model
    }

    private func start(_ model: AppModel, editable: Bool = true, stillThere: Bool = true) {
        model.startRecording(mode: .editSelection)
        model.setEditSelectionForTesting("原本的句子", editable: editable)
        model.selectionStillThere = { anchor in
            XCTAssertEqual(anchor.text, "原本的句子")
            return stillThere
        }
    }

    func testCloudKeyEditsTheSelectionAndPastesIt() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, box: box)
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertEqual(box.all.filter { !$0.hasPrefix("event:") }, ["keychain", "cloud"], "有 key 就走雲端，不跑本機 editor")
        XCTAssertEqual(model.isolatedPastePayload, "改好的正式版本")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "改好的正式版本")
        model.cancelProcessing()
    }

    func testWithoutCleanupItKeepsTheExistingEditorPathAndNeverReadsTheKey() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, cleanupEnabled: false, box: box)
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertFalse(box.all.contains("keychain"), "智慧整理沒開不讀 Keychain")
        XCTAssertFalse(box.all.contains("cloud"))
        XCTAssertTrue(box.all.contains("legacy"))
        XCTAssertEqual(model.isolatedPastePayload, "舊路線結果")
        model.cancelProcessing()
    }

    /// 審查 10-22（problem 1）：「後處理」總開關關著，選取（螢幕上別人的文字）不能送雲端，也不讀 Keychain——跟以前一樣不改寫。
    func testPostProcessingOffNeverSendsTheSelection() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, postProcessing: false, box: box)
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertFalse(box.all.contains("keychain"), "後處理關著不讀 Keychain")
        XCTAssertFalse(box.all.contains("cloud"), "後處理關著不送雲端")
        XCTAssertFalse(box.all.contains("legacy"), "本機 editor 也不跑（跟以前一樣）")
        XCTAssertNil(model.isolatedPastePayload, "不改寫選取")
        XCTAssertEqual(model.statusMessage, "Edit Selection 未完成；原選取文字未變更。後處理已關閉，選取文字沒有送出")
        model.cancelProcessing()
    }

    func testMissingKeyKeepsTheExistingEditorPath() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, key: "  ", box: box)
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertFalse(box.all.contains("cloud"))
        XCTAssertTrue(box.all.contains("legacy"))
        model.cancelProcessing()
    }

    func testChangedSelectionIsNotReplaced() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, box: box)
        start(model, stillThere: false)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertNil(model.isolatedPastePayload, "選取換了：不貼")
        XCTAssertTrue(box.all.contains("event:selection-changed"))
        XCTAssertTrue(box.all.contains("event:undelivered"))
        XCTAssertEqual(model.preferences.historyRecords.first?.note, "未送達：選取已改變")
        XCTAssertEqual(model.lastOutput, "改好的正式版本", "結果留著可複製")
        model.cancelProcessing()
    }

    func testReadOnlySelectionIsNotReplaced() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, box: box)
        start(model, editable: false)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertNil(model.isolatedPastePayload)
        XCTAssertEqual(model.preferences.historyRecords.first?.note, "未送達：選取的文字不能編輯")
        model.cancelProcessing()
    }

    func testCloudFailureOrAssistantChatterLeavesTheSelectionAlone() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let box = EventBox()
        let model = editModel(context, box: box)
        model.cloudEditRunner = { _, _, _ in throw URLError(.timedOut) }
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertNil(model.isolatedPastePayload)
        XCTAssertTrue(model.statusMessage.hasPrefix("Edit Selection 未完成；原選取文字未變更"), model.statusMessage)

        model.cloudEditRunner = { _, _, _ in "好的，以下是修改後的文字：改好的版本" }
        start(model)
        await model.completeSyntheticDictation("改正式一點")
        XCTAssertNil(model.isolatedPastePayload, "助理口吻的回覆不能取代選取")
        model.cancelProcessing()
    }

    func testSelectionCheckIsSharedWithAskAnything() {
        XCTAssertFalse(AppModel.stillAtField(pid: nil, element: nil, range: nil, expectSelection: "x"),
                       "沒有開始時的 App／欄位＝不能確認＝不貼")
    }
}

// MARK: - context-awareness-v2：擋下的原因

@MainActor
final class SelectionBlockMessageTests: XCTestCase {
    private func model(_ context: IsolatedContext) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.appLanguage = .traditionalChinese
        return AppModel(preferences: preferences)
    }

    func testListedAndUnverifiableSayDifferentThings() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = model(context)
        let listed = LimitedAppContext(contextBlocked: true, contextBlockReason: .listed)
        let unknown = LimitedAppContext(contextBlocked: true, contextBlockReason: .unverifiable)
        let legacy = LimitedAppContext(contextBlocked: true)
        XCTAssertEqual(model.selectionBlockedMessage(listed), "這個網站在「不讀脈絡的網站」清單裡；沒有讀取選取文字")
        XCTAssertEqual(model.selectionBlockedMessage(legacy), model.selectionBlockedMessage(listed), "沒有原因＝舊行為")
        let message = try XCTUnwrap(model.selectionBlockedMessage(unknown))
        XCTAssertTrue(message.hasPrefix("讀不到這個網頁的網址"), message)
        XCTAssertFalse(message.contains("清單裡；"), "網址讀不到不能說成「在清單裡」")
        XCTAssertNil(model.selectionBlockedMessage(LimitedAppContext(selectedText: "x")))
    }

    func testEditAndExplainUseTheBlockReasonBeforeAskingForASelection() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = model(context)
        let unknown = LimitedAppContext(contextBlocked: true, contextBlockReason: .unverifiable)
        XCTAssertEqual(model.editSelectionProblem(unknown), model.selectionBlockedMessage(unknown))
        XCTAssertEqual(model.explainSelectionProblem(unknown, action: .explain), model.selectionBlockedMessage(unknown),
                       "白話解釋以前在這裡說「先選取一段文字」")
        XCTAssertEqual(model.editSelectionProblem(LimitedAppContext(selectedText: "  ")),
                       "目前 App 沒有可讀取的選取文字；未替換任何內容")
        XCTAssertTrue(model.explainSelectionProblem(LimitedAppContext(), action: .translate)?.hasPrefix("先選取一段文字") == true)
        XCTAssertNil(model.editSelectionProblem(LimitedAppContext(selectedText: "原文")))
        // 審查 10-22（problem 4）：選取超過上限只讀得到前段——開始時就說「太長」，不是講完才說「選取已經改變」。
        let long = String(repeating: "甲", count: 12_500) + "結尾段落不能丟"
        let truncated = LimitedAppContext(selectedText: ContextBounds.boundedSelectedText(long),
                                          selectedTextTruncated: ContextBounds.selectionExceedsLimit(long))
        XCTAssertEqual(model.editSelectionProblem(truncated), "選取的文字太長（超過 12000 字），沒有改寫；請選短一點再試")
        XCTAssertNil(model.editSelectionProblem(LimitedAppContext(selectedText: String(repeating: "甲", count: 12_000))),
                     "剛好 12000 字沒有截斷，照常改寫")
        XCTAssertNil(model.explainSelectionProblem(LimitedAppContext(selectedText: "原文"), action: .explain))
    }
}

// MARK: - modes-3：Electron／Chromium 打開 AXManualAccessibility

@MainActor
final class ChromiumAccessibilityTests: XCTestCase {
    func testDetectsElectronCEFAndRenamedChromiumFrameworks() {
        let marker: (String) -> Bool = { ["Google Chrome Framework.framework", "Lark Framework.framework"].contains($0) }
        XCTAssertTrue(ChromiumAccessibility.isChromiumBased(frameworkNames: ["Electron Framework.framework", "Squirrel.framework"],
                                                            hasChromiumMarker: { _ in false }))
        XCTAssertTrue(ChromiumAccessibility.isChromiumBased(frameworkNames: ["Chromium Embedded Framework.framework"],
                                                            hasChromiumMarker: { _ in false }))
        XCTAssertTrue(ChromiumAccessibility.isChromiumBased(frameworkNames: ["Google Chrome Framework.framework"], hasChromiumMarker: marker))
        XCTAssertTrue(ChromiumAccessibility.isChromiumBased(frameworkNames: ["Lark Framework.framework"], hasChromiumMarker: marker))
        // 不該擋到的：原生 App、名字像但沒有 Chromium 資源檔的 framework。
        XCTAssertFalse(ChromiumAccessibility.isChromiumBased(frameworkNames: ["OutlookRightsFramework.framework", "Chart.framework"],
                                                             hasChromiumMarker: { _ in true }))
        XCTAssertFalse(ChromiumAccessibility.isChromiumBased(frameworkNames: ["Sparkle.framework", "Audio Framework.framework"],
                                                             hasChromiumMarker: { _ in false }))
        XCTAssertFalse(ChromiumAccessibility.isChromiumBased(frameworkNames: [], hasChromiumMarker: { _ in true }))
    }

    func testSetsOncePerProcessAndOnlyForChromium() {
        let helper = ChromiumAccessibility()
        var sets: [Int32] = []
        helper.detector = { $0 == 42 }
        helper.setter = { sets.append($0); return true }
        XCTAssertTrue(helper.enableIfNeeded(pid: 42, launchKey: "a"), "第一次：剛打開")
        XCTAssertFalse(helper.enableIfNeeded(pid: 42, launchKey: "a"), "同一個行程不重設")
        XCTAssertFalse(helper.enableIfNeeded(pid: 7, launchKey: "a"), "不是 Chromium：不碰")
        XCTAssertTrue(helper.enableIfNeeded(pid: 42, launchKey: "b"), "pid 被新行程重用＝重新判斷")
        XCTAssertEqual(sets, [42, 42])
        helper.detector = { _ in true }
        helper.setter = { sets.append($0); return false }
        XCTAssertFalse(helper.enableIfNeeded(pid: 9, launchKey: "a"), "設定失敗：不算剛打開，呼叫端不用等")
        XCTAssertFalse(helper.enableIfNeeded(pid: 9, launchKey: "a"))
        XCTAssertEqual(sets, [42, 42, 9], "失敗也只試一次，不會每按一次快捷鍵就重設")
    }

    func testUsesManualAccessibilityNeverEnhancedUserInterface() throws {
        XCTAssertEqual(ChromiumAccessibility.attributeName, "AXManualAccessibility")
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("\"AXEnhancedUserInterface\""), "\(file.lastPathComponent) 用了 AXEnhancedUserInterface")
            XCTAssertFalse(text.contains("kAXEnhancedUserInterface"), file.lastPathComponent)
        }
    }
}

// MARK: - modes-v2：錄音圓球的模式標籤

@MainActor
final class OverlayBadgeTests: XCTestCase {
    func testBadgePriorityAndEndonyms() {
        XCTAssertEqual(OverlayBadge.text(translation: .english, ask: false, editSelection: false, zh: true), "→ English")
        XCTAssertEqual(OverlayBadge.text(translation: .japanese, ask: false, editSelection: false, zh: false), "→ 日本語")
        XCTAssertEqual(OverlayBadge.text(translation: .simplifiedChinese, ask: false, editSelection: false, zh: true), "→ 简体中文")
        XCTAssertEqual(OverlayBadge.text(translation: .off, ask: true, editSelection: false, zh: true), "Ask anything")
        XCTAssertEqual(OverlayBadge.text(translation: .english, ask: true, editSelection: false, zh: true), "Ask anything", "Ask 優先")
        XCTAssertEqual(OverlayBadge.text(translation: .off, ask: false, editSelection: true, zh: true), "改寫選取")
        XCTAssertEqual(OverlayBadge.text(translation: .off, ask: false, editSelection: true, zh: false), "Edit Selection")
        XCTAssertNil(OverlayBadge.text(translation: .off, ask: false, editSelection: false, zh: true), "一般聽寫不顯示")
        for target in TranslationTarget.allCases where target != .off {
            XCTAssertFalse(target.endonym.isEmpty, "\(target)")
        }
    }

    func testPlainDictationKeepsTheOrbSize() {
        XCTAssertEqual(OverlayWindowController.panelSize(badge: nil), NSSize(width: 96, height: 96))
        let badged = OverlayWindowController.panelSize(badge: "→ English")
        XCTAssertEqual(badged.width, OverlayWindowController.badgeWidth)
        XCTAssertEqual(badged.height, 96 + OverlayWindowController.badgeGap + OverlayWindowController.badgeHeight)
    }

    func testModelExposesTheTranslationTargetOfTheCurrentRecording() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.pushToTalkEnabled = false
        preferences.mode = .smart
        let model = AppModel(preferences: preferences)
        model.shortcutPressed(translation: .english)
        XCTAssertEqual(model.overlayBadge, "→ English")
        model.cancelRecording()
        model.shortcutPressed()
        XCTAssertNil(model.overlayBadge)
        model.cancelRecording()
    }
}

// MARK: - app-shell-5：首頁快捷鍵卡

final class ShortcutCheatSheetTests: XCTestCase {
    private let slots: [ShortcutCheatSheet.TranslationSlot] = [.shift(.english), .command(.japanese), .control(.off)]

    func testFixedOrderAndDefaultShortcuts() {
        let items = ShortcutCheatSheet.items(dictate: "⌥Space", slots: slots, ask: "⌘⌥A", explain: "⌃⌥E",
                                             translateSelection: "⌃⌥T", zh: true)
        XCTAssertEqual(items.map(\.id), ["dictate", "translate-⇧", "translate-⌘", "ask", "explain", "translate-selection"])
        XCTAssertEqual(items.map(\.keys), ["⌥Space", "⇧ + ⌥Space", "⌘ + ⌥Space", "⌘⌥A", "⌃⌥E", "⌃⌥T"])
        XCTAssertEqual(items[1].title, "翻成英文")
        XCTAssertEqual(items[3].title, "Ask anything")
    }

    func testEmptyShortcutsAndUnregisteredVariantsAreSkipped() {
        let noAsk = ShortcutCheatSheet.items(dictate: "⌥Space", slots: slots, ask: " ", explain: "",
                                             translateSelection: "⌃⌥T", zh: false)
        XCTAssertEqual(noAsk.map(\.id), ["dictate", "translate-⇧", "translate-⌘", "translate-selection"])
        XCTAssertEqual(noAsk[1].title, "Translate → English")
        // 聽寫快捷鍵本身含 ⇧：⇧ 變體不會註冊，也不列。
        let shifted = ShortcutCheatSheet.items(dictate: "⇧⌥Space", slots: slots, ask: "", explain: "",
                                               translateSelection: "", zh: true)
        XCTAssertEqual(shifted.map(\.id), ["dictate", "translate-⌘"])
        // 沒有聽寫快捷鍵：沒有聽寫也沒有翻譯變體。
        let none = ShortcutCheatSheet.items(dictate: "", slots: slots, ask: "⌘⌥A", explain: "", translateSelection: "", zh: true)
        XCTAssertEqual(none.map(\.id), ["ask"])
    }

    @MainActor
    func testReadsCurrentPreferences() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.translationSlotControl = .korean
        let ids = ShortcutCheatSheet.items(for: preferences).map(\.id)
        XCTAssertEqual(ids.first, "dictate")
        XCTAssertTrue(ids.contains("translate-⌃"))
    }
}

// MARK: - delivery-learning-6：剪貼簿衛生＋依鍵盤配置找 V

@MainActor
final class ClipboardHygieneTests: XCTestCase {
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.utuvo.type.tests.\(UUID().uuidString)"))
    }

    func testRestoreWritesAreMarkedTransientButNotConcealed() {
        let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ClipboardPaster.writeForPaste("合成測試文字", to: pasteboard, handling: .restore))
        let types = pasteboard.types ?? []
        XCTAssertEqual(pasteboard.string(forType: .string), "合成測試文字")
        XCTAssertTrue(types.contains(ClipboardPaster.transientType), "剪貼簿管理工具不要記")
        XCTAssertFalse(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")), "不是密碼")
    }

    func testKeepWritesAreOrdinaryCopies() {
        let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(ClipboardPaster.writeForPaste("合成測試文字", to: pasteboard, handling: .keep))
        let types = pasteboard.types ?? []
        XCTAssertEqual(pasteboard.string(forType: .string), "合成測試文字")
        XCTAssertFalse(types.contains(ClipboardPaster.transientType), "使用者要留著：照一般複製")
    }

    func testListsStillCarryHTML() {
        let pasteboard = scratchPasteboard(); defer { pasteboard.releaseGlobally() }
        let text = "1. 第一項\n2. 第二項\n3. 第三項"
        ClipboardPaster.writeForPaste(text, to: pasteboard, handling: .restore)
        XCTAssertEqual(pasteboard.string(forType: .html) != nil, RichTextShape.html(for: text) != nil)
    }

    func testCommandVFollowsTheKeyboardLayout() {
        let qwerty: [CGKeyCode: String] = [9: "v", 47: "."]
        let dvorak: [CGKeyCode: String] = [9: ".", 47: "v"]
        XCTAssertEqual(KeyboardLayoutKeyCode.resolve(character: "v") { qwerty[$0] }, 9)
        XCTAssertEqual(KeyboardLayoutKeyCode.resolve(character: "v") { dvorak[$0] }, 47, "Dvorak 的 V 不在 keycode 9")
        XCTAssertEqual(KeyboardLayoutKeyCode.resolve(character: "v") { _ in nil }, 9, "查不到就跟以前一樣")
        XCTAssertEqual(KeyboardLayoutKeyCode.resolve(character: "v") { $0 == 30 ? "V" : nil }, 30, "大小寫不影響")
        XCTAssertTrue((0..<128).contains(Int(KeyboardLayoutKeyCode.commandV())), "目前配置查得到一個合法 keycode")
    }
}

// MARK: - app-shell-7：Mac 語言變體

@MainActor
final class LanguageVariantMacTests: XCTestCase {
    private func config(_ variant: CleanupVariant? = nil, language: String = "zh-TW",
                        context: CleanupPromptContext = .init()) -> CleanupConfig {
        var config = CleanupConfig(enabled: true, provider: .custom, customEndpoint: "https://fixture.invalid/completions",
                                   customModel: "synthetic-model", language: language, personal: [:], enabledPacks: [])
        config.context = context
        if let variant { config.variant = variant }
        return config
    }

    private func systemPrompt(_ config: CleanupConfig, text: String = "明天再跟你說") async throws -> String {
        let transport = MockCleanupTransport()
        transport.register(host: "fixture.invalid", bodyJSON: ["choices": [["message": ["content": text]]]])
        _ = await SmartCleanup.clean(text, config: config, transport: transport,
                                     credentialLookup: { _ in "synthetic-key" }, log: InMemoryCleanupLog())
        let body = try XCTUnwrap(transport.lastRequest?.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        return try XCTUnwrap(messages.first?["content"] as? String)
    }

    func testDefaultPromptIsByteIdentical() async throws {
        let implicit = try await systemPrompt(config())
        let explicit = try await systemPrompt(config(CleanupVariant.none))
        XCTAssertEqual(implicit, explicit)
        XCTAssertEqual(implicit, CleanupPromptRules.apply(SmartCleanup.instructions, autoList: true),
                       "預設（沒有詞庫、沒有脈絡、沒選變體）＝原本的整理提示詞，一個 byte 都不多")
        for variant in CleanupVariant.allCases where variant != .none {
            XCTAssertFalse(implicit.contains(variant.promptInstruction!))
        }
    }

    func testBritishEnglishAppendsTheVariantBeforeTheAppContext() async throws {
        let base = try await systemPrompt(config(language: "en-US"), text: "see you tomorrow")
        let british = try await systemPrompt(config(.enGB, language: "en-US", context: .init(appName: "Mail")),
                                             text: "see you tomorrow")
        XCTAssertTrue(british.hasPrefix(base + "\n" + CleanupVariant.enGBInstruction))
        XCTAssertTrue(british.contains("British English"))
        let variantAt = try XCTUnwrap(british.range(of: CleanupVariant.enGBInstruction)).lowerBound
        let contextAt = try XCTUnwrap(british.range(of: "目前 App：")).lowerBound
        XCTAssertLessThan(variantAt, contextAt, "跟 iOS 一樣：變體在 App 脈絡之前")
    }

    func testPreferenceMapsChineseVariantsToOutputScript() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.effectiveLanguageVariant, CleanupVariant.none, "預設＝none")
        preferences.setLanguageVariant(.zhCN, for: .traditionalChinese)
        XCTAssertEqual(preferences.outputScript, .simplified)
        XCTAssertEqual(preferences.effectiveLanguageVariant, .zhCN)
        preferences.outputScript = .traditional
        XCTAssertEqual(preferences.effectiveLanguageVariant, CleanupVariant.none, "字形改回繁體：簡體要求不送")
        preferences.setLanguageVariant(.zhHK, for: .traditionalChinese)
        XCTAssertEqual(preferences.outputScript, .traditional)
        XCTAssertEqual(preferences.effectiveLanguageVariant, .zhHK)
        preferences.setLanguageVariant(.enGB, for: .traditionalChinese)
        XCTAssertEqual(preferences.languageVariant(for: .traditionalChinese), .zhHK, "別的語言的變體不收")
        preferences.setLanguageVariant(.enGB, for: .english)
        preferences.transcriptionLanguage = .english
        XCTAssertEqual(preferences.effectiveLanguageVariant, .enGB, "每個語言各記各的")
        let reread = AppPreferences(isolation: context)
        XCTAssertEqual(reread.languageVariant(for: .traditionalChinese), .zhHK, "存得起來")
        XCTAssertEqual(reread.languageVariant(for: .english), .enGB)
        XCTAssertEqual(reread.languageVariant(for: .japanese), CleanupVariant.none)
    }

    func testDictationCleanupCarriesTheVariant() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in ContinuationFixture(before: nil) }
        final class Box: @unchecked Sendable { var variants: [CleanupVariant] = [] }
        let box = Box()
        model.cleanupRunner = { _, config in box.variants.append(config.variant); return nil }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()
        preferences.setLanguageVariant(.zhTW, for: .traditionalChinese)
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("合成測試文字")
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(box.variants, [CleanupVariant.none, .zhTW])
        model.cancelProcessing()
    }

    func testHongKongSkipsTaiwanFixesOnGroqText() {
        let taiwan = MacCloudASR.accept("这个软件很好", language: "zh-TW", outputScript: .traditional, seconds: 2)
        let hongKong = MacCloudASR.accept("这个软件很好", language: "zh-TW", outputScript: .traditional, seconds: 2,
                                          taiwanFixes: false)
        XCTAssertEqual(taiwan, "這個軟體很好", "預設照舊：台灣用字")
        XCTAssertEqual(hongKong, "這個軟件很好", "香港繁體：只轉字形，不改成台灣用字")
    }
}
