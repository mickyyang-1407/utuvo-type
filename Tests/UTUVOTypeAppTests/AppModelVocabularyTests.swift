import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

@MainActor
private final class VocabularyFixtureDestination: DictationDestination {
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

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

/// asr-vocab-2 接線（2026-10-22）：智慧整理回來的文字通過把關之後、送出之前，補套使用者的「英文專名＋個人字典」。
/// bench：本機整理版已經把「Darmy Music」修成「DAMI music」，Claude 讀的是原始逐字稿、又寫回「Darmy Music」，
/// 背景替換把對的蓋成錯的。三條送出路都要補：背景替換、剪貼簿退路、翻譯前的整理。全部在隔離模式跑，不碰網路、Keychain。
@MainActor
final class AppModelVocabularyTests: XCTestCase {
    private let heard = "我在 Darmy Music 用 Utuvo Type 寫歌詞"
    private let fixed = "我在 DAMI music 用 UTUVO Type 寫歌詞"

    private func model(_ context: IsolatedContext, target: VocabularyFixtureDestination, cleaned: String) -> AppModel {
        let preferences = AppPreferences(isolation: context)
        preferences.cleanupEnabled = true
        preferences.cleanupProvider = .claude   // bench 的情境：Claude 用寬鬆把關，名字拼錯照樣會過關
        preferences.appendTrailingSpace = true
        preferences.dictionaryJSON = #"{"DAMI music":""}"#   // 詞彙模式：輸出寫法留空＝詞本身
        let model = AppModel(preferences: preferences)
        model.captureDestination = { _ in target }
        model.cleanupRunner = { _, _ in cleaned }
        return model
    }

    func testBackgroundReplacementKeepsPersonalSpellingAfterCleanup() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = VocabularyFixtureDestination()
        let model = model(context, target: target, cleaned: heard + "。")
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(heard)
        XCTAssertEqual(target.text, fixed + " ", "先貼的本機整理版本來就修好了")
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(target.replacements, 1, "整理版有通過把關、有換上去")
        XCTAssertEqual(target.text, fixed + " ")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, fixed)
        model.cancelProcessing()
    }

    func testClipboardFallbackKeepsPersonalSpellingAfterCleanup() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = VocabularyFixtureDestination(); target.valid = false
        let model = model(context, target: target, cleaned: heard + "。")
        var events: [String] = []
        model.onDeliveryEvent = { events.append($0) }
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation(heard)
        await model.waitForBackgroundCleanup()
        XCTAssertEqual(events.last, "fallback")
        XCTAssertEqual(model.lastOutput, fixed)
        XCTAssertEqual(model.preferences.historyRecords.first?.output, fixed)
        model.cancelProcessing()
    }

    func testTranslationCleansWithPersonalSpellingBeforeTranslating() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = VocabularyFixtureDestination()
        let model = model(context, target: target, cleaned: heard + "。")
        model.cleanupKeyLookup = { _ in "synthetic-key" }
        let sent = TextBox()
        model.cloudTranslationRunner = { _, text, _ in sent.add(text); return "Synthetic translation." }
        model.systemTranslationRunner = { _, _, _ in nil }
        await model.completeSyntheticDictation(heard, translation: .english)
        XCTAssertEqual(sent.all, [fixed + "。"], "送去翻譯的是補過詞的整理版")
        XCTAssertEqual(model.preferences.historyRecords.first?.output, "Synthetic translation.")
    }

    /// 翻譯失敗時改貼的原文＝整理版，也要是補過詞的。
    func testFailedTranslationPastesCorrectedCleanup() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = VocabularyFixtureDestination()
        let model = model(context, target: target, cleaned: heard + "。")
        model.cleanupKeyLookup = { _ in "synthetic-key" }
        model.cloudTranslationRunner = { _, _, _ in throw URLError(.timedOut) }
        model.systemTranslationRunner = { _, _, _ in nil }
        await model.completeSyntheticDictation(heard, translation: .english)
        let output = try XCTUnwrap(model.preferences.historyRecords.first?.output)
        XCTAssertTrue(output.hasPrefix(fixed), output)
        XCTAssertFalse(output.contains("Darmy"), output)
    }

    /// 不該改：整理版本來就寫對（冪等），或是一般英文（phone、shop、types、stock 不能被拉成 iPhone／Zhipu／Typeless／SDK）。
    func testCorrectCleanupIsDeliveredByteIdentical() async throws {
        for (spoken, cleaned) in [(fixed, fixed + "。"),
                                  ("我的 phone 拿去 shop 修了，這些 types 的 stock 都還在", "我的 phone 拿去 shop 修了，這些 types 的 stock 都還在。")] {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let target = VocabularyFixtureDestination()
            let model = model(context, target: target, cleaned: cleaned)
            model.preferences.enabledVocabularyPackIDs = BuiltInVocabulary.ids
            model.startRecording(mode: .smart)
            await model.completeSyntheticDictation(spoken)
            await model.waitForBackgroundCleanup()
            XCTAssertEqual(target.replacements, 1, spoken)
            XCTAssertEqual(target.text, SentenceMood.finish(cleaned) + " ")
            XCTAssertEqual(model.applyingVocabulary(cleaned, dictionary: model.preferences.dictionary), cleaned)
            model.cancelProcessing()
        }
    }

    /// FX-5：先貼的本機整理版（deterministic 路徑）不准把一般英文改成產品名——修之前 Mac 的 AI 名稱把
    /// 「I'm glad the cloud sync works」貼成「I'm Claude the Claude sync works」。不是英文字的（Gimani）照修。
    func testFirstPasteLeavesCommonEnglishAlone() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let target = VocabularyFixtureDestination()
        let model = model(context, target: target, cleaned: "")
        model.preferences.cleanupEnabled = false
        model.preferences.enabledVocabularyPackIDs = BuiltInVocabulary.ids
        model.startRecording(mode: .smart)
        await model.completeSyntheticDictation("I'm glad the cloud sync works with Gimani")
        XCTAssertTrue(target.text.hasPrefix("I'm glad the cloud sync works with Gemini"), target.text)
        XCTAssertFalse(target.text.contains("Claude"), target.text)
        model.cancelProcessing()
    }

    /// 音訊包關著（預設）：「Protus」不能被拉到 Uber Eats（個人字典裡有 Uber Eats）。
    func testProtusIsNotPulledToUberEats() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let model = model(context, target: VocabularyFixtureDestination(), cleaned: "")
        model.preferences.dictionaryJSON = #"{"優吃":"Uber Eats"}"#
        XCTAssertEqual(model.applyingVocabulary("更新 Protus", dictionary: model.preferences.dictionary), "更新 Protus")
        model.preferences.enabledVocabularyPackIDs.insert("audio")
        XCTAssertEqual(model.applyingVocabulary("更新 Protus", dictionary: model.preferences.dictionary), "更新 Pro Tools")
    }
}
