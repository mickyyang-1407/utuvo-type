import XCTest
import UIKit
@testable import UTUVOTypeiOS

/// 鍵盤純邏輯：模式判定、送出鍵文案、用量統計。
final class KeyboardLogicTests: XCTestCase {
    func testModeDecision() {
        XCTAssertEqual(KeyboardMode.decide(selectedText: nil, translateTarget: nil), .dictate)
        XCTAssertEqual(KeyboardMode.decide(selectedText: "   ", translateTarget: nil), .dictate)
        XCTAssertEqual(KeyboardMode.decide(selectedText: "hello", translateTarget: nil), .edit(selection: "hello"))
        let ja = TranslationTarget.all.first { $0.code == "ja" }!
        // 剛長按選了語言＝翻譯優先，即使有選取
        XCTAssertEqual(KeyboardMode.decide(selectedText: "hello", translateTarget: ja), .translate(target: ja))
    }

    func testNoModeInsertsPartials() {
        let ja = TranslationTarget.all.first { $0.code == "ja" }!
        XCTAssertFalse(KeyboardMode.dictate.insertsPartials)
        XCTAssertFalse(KeyboardMode.edit(selection: "x").insertsPartials)
        XCTAssertFalse(KeyboardMode.translate(target: ja).insertsPartials)
    }

    func testShouldFlushPendingBeforeStartTruthTable() {
        // 翻譯／編輯模式不該 flush（沒有「整理中」階段）。
        let notDictating = KeyboardMode.edit(selection: "x")
        XCTAssertFalse(notDictating == .dictate)
        XCTAssertFalse(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: false,
                                                                  hasPendingCommand: true,
                                                                  isRecording: false,
                                                                  lastTranscript: "明天下午三點"))
        // 沒等待中的指令：false
        XCTAssertFalse(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: true,
                                                                  hasPendingCommand: false,
                                                                  isRecording: false,
                                                                  lastTranscript: "明天下午三點"))
        // 正在錄音：false（會走 stop 分支，不會走 flush）
        XCTAssertFalse(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: true,
                                                                  hasPendingCommand: true,
                                                                  isRecording: true,
                                                                  lastTranscript: "明天下午三點"))
        // 全空白：false
        XCTAssertFalse(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: true,
                                                                  hasPendingCommand: true,
                                                                  isRecording: false,
                                                                  lastTranscript: "   \n\t "))
        XCTAssertFalse(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: true,
                                                                  hasPendingCommand: true,
                                                                  isRecording: false,
                                                                  lastTranscript: ""))
        // 全成立：true
        XCTAssertTrue(KeyboardMode.shouldFlushPendingBeforeStart(isDictating: true,
                                                                 hasPendingCommand: true,
                                                                 isRecording: false,
                                                                 lastTranscript: "明天下午三點"))
    }

    func testPendingTranscriptIgnoresWhenNoOrMismatchedID() {
        let id = UUID()
        // pendingID 為 nil → 用 local
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "明天下午三點",
                                                     pendingID: nil,
                                                     sharedCommandID: id,
                                                     sharedPartial: "partial 文字",
                                                     sharedFinal: nil),
                       "明天下午三點")
        // sharedCommandID 不符 → 用 local（不要拿錯段的文字）
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "明天下午三點",
                                                     pendingID: id,
                                                     sharedCommandID: UUID(),
                                                     sharedPartial: "partial 文字",
                                                     sharedFinal: nil),
                       "明天下午三點")
    }

    func testPendingTranscriptPrefersSharedWhenLocalEmpty() {
        let id = UUID()
        // local 空、shared partial 有字 → shared
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "",
                                                     pendingID: id,
                                                     sharedCommandID: id,
                                                     sharedPartial: "明天下午三點",
                                                     sharedFinal: nil),
                       "明天下午三點")
    }

    func testPendingTranscriptPrefersFinalOverPartial() {
        let id = UUID()
        // sharedFinal 優先於 sharedPartial
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "短",
                                                     pendingID: id,
                                                     sharedCommandID: id,
                                                     sharedPartial: "partial 文字",
                                                     sharedFinal: "final 文字"),
                       "final 文字")
    }

    func testPendingTranscriptPrefersFinalEvenWhenShorter() {
        // R3-3（luna-review 2026-09-25）：sharedFinal 是主 app 走過字典的最終版，比 partial 權威；
        // 不比長度（定稿可能比 partial 短）。
        let id = UUID()
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "很長很長的 local 文字",
                                                     pendingID: id,
                                                     sharedCommandID: id,
                                                     sharedPartial: "partial 文字",
                                                     sharedFinal: "短"),
                       "短")
    }

    func testPendingTranscriptFallsBackToLocalWhenSharedShorter() {
        let id = UUID()
        // shared 比 local 短 → 用 local（空白誤觸或被截斷時不要撐場）
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "明天下午三點在錄音室",
                                                     pendingID: id,
                                                     sharedCommandID: id,
                                                     sharedPartial: "你好",
                                                     sharedFinal: nil),
                       "明天下午三點在錄音室")
    }

    func testPendingTranscriptFallsBackToLocalWhenSharedAllWhitespace() {
        let id = UUID()
        // shared 全空白（partial 與 final 都沒字） → 用 local
        XCTAssertEqual(KeyboardMode.pendingTranscript(local: "明天下午三點",
                                                     pendingID: id,
                                                     sharedCommandID: id,
                                                     sharedPartial: "   \n\t ",
                                                     sharedFinal: nil),
                       "明天下午三點")
    }

    func testQuickPickDefaultsHaveEnglishInTheMiddle() {
        XCTAssertEqual(QuickPickStore.resolve(nil), ["ja", "ko", "en", "zh-Hant", "fr"])
        XCTAssertEqual(QuickPickStore.resolve(nil)[2], "en")
    }

    func testQuickPickResolveCleansUnknownDuplicatesAndCaps() {
        XCTAssertEqual(QuickPickStore.resolve(["de", "xx", "de", "es"]), ["de", "es"], "不認得的、重複的丟掉")
        XCTAssertEqual(QuickPickStore.resolve(["en", "ja", "ko", "fr", "de", "es", "it"]).count, 5, "最多 5 個")
        XCTAssertEqual(QuickPickStore.resolve([]), QuickPickStore.defaultCodes, "空的回預設，鍵盤長按不能沒語言")
    }

    func testQuickPickToggle() {
        XCTAssertEqual(QuickPickStore.toggled("de", in: ["en"]), ["en", "de"], "加到最後")
        XCTAssertEqual(QuickPickStore.toggled("en", in: ["en", "de"]), ["de"], "已選就移除")
        XCTAssertEqual(QuickPickStore.toggled("en", in: ["en"]), ["en"], "最後一個不能移除")
        XCTAssertEqual(QuickPickStore.toggled("it", in: ["en", "ja", "ko", "fr", "de"]), ["en", "ja", "ko", "fr", "de"], "滿 5 個不加")
    }

    func testQuickPickPersistsThroughDefaults() {
        let suite = UserDefaults(suiteName: "test.quickpick.\(UUID().uuidString)")!
        QuickPickStore.setCodes(["vi", "th", "id"], in: suite)
        XCTAssertEqual(QuickPickStore.targets(in: suite).map(\.zh), ["越南文", "泰文", "印尼文"])
    }

    func testReturnKeyLabels() {
        XCTAssertEqual(ReturnKeyLabel.text(for: .send), "送出")
        XCTAssertEqual(ReturnKeyLabel.text(for: .search), "搜尋")
        XCTAssertEqual(ReturnKeyLabel.text(for: .done), "完成")
        XCTAssertEqual(ReturnKeyLabel.text(for: .default), "換行")
        XCTAssertEqual(ReturnKeyLabel.text(for: nil), "換行")
    }

    func testToneChatDropsSingleTrailingPeriod() {
        XCTAssertEqual(ToneHint.infer(returnKeyType: .send), .chat)
        XCTAssertEqual(ToneHint.infer(returnKeyType: .default), .document)
        XCTAssertTrue(ToneHint.allowsLineBreaks(returnKeyType: .default))
        XCTAssertTrue(ToneHint.allowsLineBreaks(returnKeyType: nil))
        for single in [UIReturnKeyType.send, .search, .go, .done, .next, .join, .route, .google, .yahoo, .emergencyCall, .continue] {
            XCTAssertFalse(ToneHint.allowsLineBreaks(returnKeyType: single), "\(single.rawValue)")
        }
        // 2026-10-02 Micky：最後一句不加句號——聊天框、文件都一樣；中間的句號留著；問號驚嘆號不動；分段長文照原樣。
        XCTAssertEqual(ToneHint.apply("我十分鐘到。", tone: .chat), "我十分鐘到")
        XCTAssertEqual(ToneHint.apply("我十分鐘到。", tone: .document), "我十分鐘到")
        XCTAssertEqual(ToneHint.apply("先開會。再吃飯。", tone: .chat), "先開會。再吃飯")
        XCTAssertEqual(ToneHint.apply("你到了嗎？", tone: .chat), "你到了嗎？")
        XCTAssertEqual(ToneHint.apply("第一段。\n\n第二段。", tone: .document), "第一段。\n\n第二段。")
        XCTAssertEqual(ToneHint.apply("好", tone: .chat), "好")
    }

    func testPipelineAppliesTaiwanPhrasesBeforeDictionary() {
        // 字典後套：使用者若把「軟體」再改成「Software」，字典要贏
        // 字典規則：右側緊接文字時視為更長詞的一部分而不換，所以用句尾／標點前的位置測
        let pipeline = TextPipeline(dictionary: ["軟體": "Software"])
        XCTAssertEqual(pipeline.clean("我在用軟件，很好用").output, "我在用Software，很好用")
        XCTAssertEqual(TextPipeline().clean("我在用軟件，很好用").output, "我在用軟體，很好用")
        XCTAssertTrue(pipeline.clean("軟件").steps.first == "taiwan-phrases")
    }

    func testWordCountMixesCJKAndLatin() {
        XCTAssertEqual(UsageInsights.wordCount("今天下午三點開會"), 8)
        XCTAssertEqual(UsageInsights.wordCount("meet at 3 pm today"), 5)
        XCTAssertEqual(UsageInsights.wordCount("我用 UTUVO Type 打字，很快。"), 8)
        XCTAssertEqual(UsageInsights.wordCount(""), 0)
    }

    func testInsightsWeekWindowAndSavings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = DictationRecord(date: now.addingTimeInterval(-10 * 86_400), raw: "", cleaned: "十個字十個字十個字十")
        let recent = DictationRecord(date: now.addingTimeInterval(-86_400), raw: "", cleaned: "五個字五個")
        let insights = UsageInsights.compute(records: [old, recent], now: now)
        XCTAssertEqual(insights.totalWords, 15)
        XCTAssertEqual(insights.weekWords, 5)
        XCTAssertEqual(insights.sessions, 2)
        // 15 字 × (1/36 − 1/150) 分鐘 ≈ 0.317
        XCTAssertEqual(insights.minutesSaved, 15.0 * (1.0 / 36.0 - 1.0 / 150.0), accuracy: 0.0001)
    }

    // MARK: - R3-4（luna-review 2026-09-25）flushText 真值表
    // 合併 shouldFlushPendingBeforeStart 與 pendingTranscript，回要貼的文字或 nil。

    func testFlushTextReturnsNilWhenNotDictating() {
        // 翻譯／編輯模式沒有「整理中」階段
        XCTAssertNil(KeyboardMode.flushText(isDictating: false, isRecording: false, pendingID: UUID(),
                                            local: "明天下午三點", sharedCommandID: nil,
                                            sharedPartial: "", sharedFinal: nil))
    }

    func testFlushTextReturnsNilWhenRecording() {
        // 錄音中會走 stop 分支，不該 flush
        XCTAssertNil(KeyboardMode.flushText(isDictating: true, isRecording: true, pendingID: UUID(),
                                            local: "明天下午三點", sharedCommandID: nil,
                                            sharedPartial: "", sharedFinal: nil))
    }

    func testFlushTextReturnsNilWhenNoPending() {
        XCTAssertNil(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: nil,
                                            local: "明天下午三點", sharedCommandID: nil,
                                            sharedPartial: "shared 文字", sharedFinal: nil))
    }

    func testFlushTextUsesSharedWhenLocalEmpty() {
        let id = UUID()
        // local 空、shared partial 有字（同 ID）→ 用 shared
        XCTAssertEqual(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: id,
                                              local: "", sharedCommandID: id,
                                              sharedPartial: "明天下午三點", sharedFinal: nil),
                       "明天下午三點")
    }

    func testFlushTextPrefersFinalEvenWhenShorter() {
        // R3-3：sharedFinal 即使比 local 短（同 ID）也是主 app 定稿，權威最高
        let id = UUID()
        XCTAssertEqual(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: id,
                                              local: "很長很長的 local 文字", sharedCommandID: id,
                                              sharedPartial: "partial 文字", sharedFinal: "短"),
                       "短")
    }

    func testFlushTextFallsBackToLocalWhenIDMismatch() {
        let id = UUID()
        // pendingID != sharedCommandID → 用 local（local 空就 nil）
        XCTAssertEqual(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: id,
                                              local: "local 文字", sharedCommandID: UUID(),
                                              sharedPartial: "shared 文字", sharedFinal: "shared final"),
                       "local 文字")
        XCTAssertNil(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: id,
                                            local: "", sharedCommandID: UUID(),
                                            sharedPartial: "shared 文字", sharedFinal: "shared final"))
    }

    func testFlushTextReturnsNilWhenAllWhitespace() {
        let id = UUID()
        // 鍵盤 local 與 shared 都是空白（拿不到東西）→ nil，不該貼空字串
        XCTAssertNil(KeyboardMode.flushText(isDictating: true, isRecording: false, pendingID: id,
                                            local: "   \n\t ", sharedCommandID: id,
                                            sharedPartial: "   ", sharedFinal: nil))
    }
}
