import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// delivery-learning-3／-4、asr-vocab-4（Mac）：修改追蹤的結算時機、自動加入字典、提示卡與復原。
@MainActor
final class EditLearningAppTests: XCTestCase {
    private func correction(_ from: String, _ to: String) -> EditTracker.Correction { .init(from: from, to: to) }

    // MARK: - 自動加入／只留建議

    /// 2026-10-22 修補：中文要至少改兩個同音字（練係→聯繫）；英文要改成詞庫包的詞（Gemini 是內建詞）或品牌寫法。
    /// （原本用「元山→圓山」只改一個字、「Protus→Pro Tools」不在詞庫包，修補後都只留建議，見下面的修補測試。）
    func testHomophoneAndEnglishNameFixesAreAutoAddedAndTaggedAuto() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let result = prefs.learn(fromEdits: [correction("練係", "聯繫"), correction("Jemini", "Gemini")])
        XCTAssertEqual(prefs.dictionary, ["練係": "聯繫", "Jemini": "Gemini"])
        XCTAssertEqual(prefs.dictionaryAutoTerms, ["練係", "Jemini"])
        XCTAssertEqual(result.added.map(\.source), ["練係", "Jemini"])
        XCTAssertTrue(result.suggested.isEmpty)
        XCTAssertTrue(prefs.dictionarySuggestions.isEmpty, "自動加的不再進建議清單")
        XCTAssertTrue(String(decoding: prefs.exportDictionaryData(), as: UTF8.self).contains(#""source" : "AUTO""#),
                      "匯出檔帶自動標記（Android 讀得懂）")
        XCTAssertEqual(AppPreferences(isolation: context).dictionaryAutoTerms, ["練係", "Jemini"], "重開還在")
    }

    func testCaseOnlyBrandFixAddsAVocabularyEntryNotAReplacement() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let result = prefs.learn(fromEdits: [correction("Utuvo", "UTUVO")])
        XCTAssertEqual(prefs.dictionary, ["UTUVO": "UTUVO"], "詞彙模式：聽到＝改後的詞、不做 Utuvo→UTUVO 硬替換")
        XCTAssertEqual(result.added.first?.isVocabulary, true)
        let terms = VocabularyPacks.latinTermsForFixer(personal: prefs.dictionary, enabled: [])
        XCTAssertEqual(LatinNameFixer.fix("我在用 Utuvo 打字", terms: terms), "我在用 UTUVO 打字", "英文專名修正吃得到這個詞")
    }

    func testContentEditsAreNeverWrittenAsReplacements() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let before = prefs.dictionaryJSON
        let found = [correction("三點", "四點"), correction("今天", "明天"), correction("tool", "Tool"), correction("meeting", "call")]
        let result = prefs.learn(fromEdits: found)
        XCTAssertEqual(prefs.dictionaryJSON, before, "改內容不寫進字典")
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(Set(result.suggested), Set(found), "只留建議，等使用者決定")
        XCTAssertEqual(Set(prefs.dictionarySuggestions), Set(found))
    }

    func testTurningLearningOffWritesNothing() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        prefs.learnFromEdits = false
        let before = prefs.dictionaryJSON
        let result = prefs.learn(fromEdits: [correction("元山", "圓山"), correction("今天", "明天")])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(prefs.dictionaryJSON, before)
        XCTAssertTrue(prefs.dictionarySuggestions.isEmpty)
    }

    func testManualEntriesAreNeverOverwritten() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        prefs.addDictionaryTerm(source: "練係", output: "聯繫人")
        let result = prefs.learn(fromEdits: [correction("練係", "聯繫")])
        XCTAssertEqual(prefs.dictionary["練係"], "聯繫人", "使用者自己設定的寫法優先")
        XCTAssertTrue(prefs.dictionaryAutoTerms.isEmpty)
        XCTAssertEqual(result.suggested, [correction("練係", "聯繫")], "改成建議讓使用者決定")
    }

    func testUndoRemovesTheEntryAndStopsRelearning() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let before = prefs.dictionaryJSON
        let first = prefs.learn(fromEdits: [correction("Jemini", "Gemini"), correction("Utuvo", "UTUVO")])
        XCTAssertEqual(first.added.count, 2)
        prefs.undoLearned(first.added)
        XCTAssertEqual(prefs.dictionary, [:])
        XCTAssertEqual(prefs.dictionaryJSON, before, "字典回到原本的樣子")
        let again = prefs.learn(fromEdits: [correction("Jemini", "Gemini"), correction("Utuvo", "UTUVO"), correction("utuvo", "UTUVO")])
        XCTAssertTrue(again.isEmpty, "復原過的不會馬上又被學回來（詞彙詞連別的拼法也一起擋）")
        XCTAssertEqual(prefs.dictionary, [:])
    }

    func testUndoDoesNotTouchAnEntryTheUserChangedMeanwhile() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let learned = prefs.learn(fromEdits: [correction("練係", "聯繫")])
        XCTAssertEqual(learned.added.count, 1)
        prefs.addDictionaryTerm(source: "練係", output: "聯繫人")
        prefs.undoLearned(learned.added)
        XCTAssertEqual(prefs.dictionary["練係"], "聯繫人")
    }

    func testRemovingAnAutoTermInSettingsIgnoresItAndRestoreBringsTheTagBack() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        XCTAssertEqual(prefs.learn(fromEdits: [correction("練係", "聯繫")]).added.count, 1)
        prefs.removeDictionaryTerm(source: "練係")
        XCTAssertTrue(prefs.learn(fromEdits: [correction("練係", "聯繫")]).isEmpty, "使用者刪掉的自動詞不再自動加回")
        prefs.restoreDictionaryTerm(source: "練係", output: "聯繫", origin: .auto)
        XCTAssertEqual(prefs.dictionaryAutoTerms, ["練係"])
        prefs.removeDictionaryTerm(source: "練係")
        prefs.restoreDictionaryTerm(source: "練係", output: "聯繫", origin: .auto)
        prefs.removeDictionaryTerm(source: "練係")
        prefs.restoreDictionaryTerm(source: "練係", output: "聯繫")
        XCTAssertTrue(prefs.dictionaryAutoTerms.isEmpty, "舊的復原呼叫照舊是手動")
    }

    // MARK: - 提示卡內容

    func testToastContentForAddedTerms() throws {
        let added = AppPreferences.EditLearningResult(added: [
            .init(correction: correction("Protus", "Pro Tools"), source: "Protus", output: "Pro Tools"),
            .init(correction: correction("Utuvo", "UTUVO"), source: "UTUVO", output: "UTUVO"),
        ])
        let zh = try XCTUnwrap(LearnedWordToast.content(for: added, zh: true))
        XCTAssertEqual(zh.kind, .added)
        XCTAssertEqual(zh.title, "已加入字典")
        XCTAssertEqual(zh.lines, ["Protus → Pro Tools", "UTUVO"])
        XCTAssertEqual(zh.primary, "復原")
        XCTAssertNil(zh.secondary)
        XCTAssertNil(zh.note)
        let en = try XCTUnwrap(LearnedWordToast.content(for: added, zh: false))
        XCTAssertEqual(en.title, "Added to dictionary")
        XCTAssertEqual(en.primary, "Undo")
    }

    func testToastContentForSuggestionsAndTruncation() throws {
        let long = "Supercalifragilistic"
        let result = AppPreferences.EditLearningResult(suggested: [correction("今天", "明天"), correction("x", long)])
        let zh = try XCTUnwrap(LearnedWordToast.content(for: result, zh: true))
        XCTAssertEqual(zh.kind, .suggested)
        XCTAssertEqual(zh.title, "要加入字典嗎？")
        XCTAssertEqual(zh.lines, ["今天 → 明天", "x → Supercalifragi…"])
        XCTAssertEqual(zh.primary, "加入")
        XCTAssertEqual(zh.secondary, "忽略")
        XCTAssertNil(LearnedWordToast.content(for: .init(), zh: true), "什麼都沒學到就不跳")
        let both = AppPreferences.EditLearningResult(
            added: [.init(correction: correction("元山", "圓山"), source: "元山", output: "圓山")],
            suggested: [correction("今天", "明天")])
        XCTAssertEqual(LearnedWordToast.content(for: both, zh: true)?.note, "另有 1 個建議在設定的「個人字典」")
    }

    // MARK: - 修改追蹤的結算時機（假的欄位，不碰 AX）

    private final class FakeField {
        var value = ""
        var focused = true
        var reads = 0
        var field: EditWatcher.Field {
            EditWatcher.Field(isFocused: { [unowned self] in self.focused },
                              read: { [unowned self] in self.reads += 1; return self.value },
                              caretOffset: { nil })
        }
    }

    private func makeWatcher(_ fake: FakeField, inserted: String) -> (EditWatcher, () -> [String]) {
        let watcher = EditWatcher()
        watcher.readDelay = .milliseconds(5)
        watcher.caretDelay = .milliseconds(1)
        var found: [String] = []
        watcher.onSuggestions = { found += $0.map { "\($0.from)→\($0.to)" } }
        fake.value = inserted
        watcher.begin(inserted: inserted, field: fake.field)
        return (watcher, { found })
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    func testFixThenReturnInAChatFieldIsLearned() async {
        let fake = FakeField()
        let (watcher, found) = makeWatcher(fake, inserted: "Utuvo Type 很好")
        await settle()
        fake.value = "UTUVO Type 很好"
        watcher.handleKey(isReturn: false)
        await settle()                       // 防抖之後讀到改好的內容
        fake.value = ""                      // 聊天 App 按 Enter 送出、欄位清空
        watcher.handleKey(isReturn: true)
        XCTAssertEqual(found(), ["Utuvo→UTUVO"])
        XCTAssertNil(watcher.session, "結算後收掉")
    }

    func testReturnRightAfterTheLastKeyLearnsNothing() async {
        let fake = FakeField()
        let (watcher, found) = makeWatcher(fake, inserted: "Utuvo Type 很好")
        await settle()
        fake.value = "UTUV Type 很好"
        watcher.handleKey(isReturn: false)
        await settle()
        fake.value = "UTUVO Type 很好"
        watcher.handleKey(isReturn: false)   // 最後一個字
        fake.value = ""
        watcher.handleKey(isReturn: true)    // 防抖還沒讀到就送出
        await settle()
        XCTAssertEqual(found(), [], "快照是改到一半的，不能學到 Utuvo→UTUV")
        XCTAssertNil(watcher.session)
    }

    func testFocusLeavingAndNextDictationBothEvaluate() async {
        let fake = FakeField()
        let (watcher, found) = makeWatcher(fake, inserted: "我搭到元山站以後再換車")
        await settle()
        fake.value = "我搭到圓山站以後再換車"
        fake.focused = false
        watcher.handleKey(isReturn: false)
        await settle()                       // 防抖讀的時候焦點已經不在這個欄位
        XCTAssertEqual(found(), ["元山→圓山"])

        let other = FakeField()
        let (next, nextFound) = makeWatcher(other, inserted: "明天跟小美吃飯")
        await settle()
        other.value = "明天跟小梅吃飯"
        next.checkNow()                      // 下一次聽寫開始
        XCTAssertEqual(nextFound(), ["小美→小梅"])

        // 2026-10-22 修補：中文單字修改用系統斷詞的整個詞當 key。「悠｜遊｜卡」「儲｜值」在這句裡都斷成單字，
        // 找不到包含修改的多字詞就不學（以前借下一個字湊成「悠卡→遊卡」「除值→儲值」）。
        let third = FakeField()
        let (last, lastFound) = makeWatcher(third, inserted: "悠悠卡記得先除值")
        await settle()
        third.value = "悠遊卡記得先儲值"
        last.checkNow()
        XCTAssertEqual(lastFound(), [])
    }

    func testSlowFieldIsNotReadOnEveryKey() async {
        let fake = FakeField()
        let (watcher, _) = makeWatcher(fake, inserted: "Utuvo Type 很好")
        var now = 0.0
        watcher.clock = { now += 0.06; return now }   // 每讀一次「花」60 ms
        watcher.handleKey(isReturn: false)
        await settle()
        let afterFirst = fake.reads
        XCTAssertTrue(watcher.slowReads)
        watcher.handleKey(isReturn: false)
        watcher.handleKey(isReturn: false)
        await settle()
        XCTAssertEqual(fake.reads, afterFirst, "慢的 App 之後不再每次按鍵都讀")
        watcher.cancel()
    }

    // MARK: - 2026-10-22 修補（verifier mac-learning2）：端到端重現

    /// 交付路徑（AppModel.normalizedForDelivery 用的同一組 Normalizer＋LatinNameFixer 詞表）。
    private func deliver(_ text: String, _ prefs: AppPreferences) -> String {
        let terms = VocabularyPacks.latinTermsForFixer(personal: prefs.dictionary, enabled: [])
        return Normalizer(options: NormalizerOptions(dictionary: prefs.dictionary, latinTerms: terms)).normalize(text).cleaned
    }

    /// 貼上 → 改字 → 防抖讀到 → 按 Enter 送出（欄位清空），結果交給 `learn(fromEdits:)`，跟 AppModel 接法一樣。
    private func editAndSend(_ prefs: AppPreferences, inserted: String, edited: String) async -> [String] {
        let fake = FakeField()
        let (watcher, found) = makeWatcher(fake, inserted: inserted)
        let forward = watcher.onSuggestions
        watcher.onSuggestions = { forward?($0); prefs.learn(fromEdits: $0) }
        await settle()
        fake.value = edited
        watcher.handleKey(isReturn: false)
        await settle()
        fake.value = ""
        watcher.handleKey(isReturn: true)
        return found()
    }

    func testSingleCharacterFixInAChatIsNeverAutoAdded() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let later = ["他們還在說，我先走了", "我還在想。", "他跑的很遠"]
        let before = later.map { deliver($0, prefs) }
        _ = await editAndSend(prefs, inserted: "好，那我們下次在說", edited: "好，那我們下次再說")
        _ = await editAndSend(prefs, inserted: "那我們明天在想辦法吧", edited: "那我們明天再想辦法吧")
        _ = await editAndSend(prefs, inserted: "他跑的很快", edited: "他跑得很快")
        XCTAssertEqual(prefs.dictionary, [:], "單字修改不寫進字典")
        XCTAssertTrue(prefs.dictionaryAutoTerms.isEmpty)
        XCTAssertEqual(later.map { deliver($0, prefs) }, before, "之後的聽寫不受影響")
    }

    func testSingleCharacterNameFixIsKeyedOnTheWholeWordNotTheNextCharacter() async throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let found = await editAndSend(prefs, inserted: "明天跟小美吃飯", edited: "明天跟小梅吃飯")
        XCTAssertEqual(found, ["小美→小梅"], "不能借下一個字湊成「美吃→梅吃」")
        XCTAssertEqual(prefs.dictionary, [:], "單字修改最多只是建議")
        XCTAssertEqual(prefs.dictionarySuggestions, [correction("小美", "小梅")])
    }

    func testEnglishNameSwapsAreNotAutoAdded() async throws {
        let cases = [("Please loop in Stephen on this", "Please loop in Steven on this", "Stephen will review the mix."),
                     ("Katherine sent the stems", "Catherine sent the stems", "Katherine is out today."),
                     ("Ask Allen about the session", "Ask Allan about the session", "Allen booked studio B."),
                     ("Erik will master it", "Eric will master it", "Erik said hi.")]
        for (inserted, edited, later) in cases {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let prefs = AppPreferences(isolation: context)
            let before = deliver(later, prefs)
            let result = prefs.learn(fromEdits: EditTracker.corrections(inserted: inserted, current: edited))
            XCTAssertTrue(result.added.isEmpty, "\(inserted) → \(edited)")
            XCTAssertEqual(prefs.dictionary, [:])
            XCTAssertEqual(deliver(later, prefs), before, "兩個不同的人不能被合併")
            XCTAssertFalse(result.suggested.isEmpty, "還是可以按「加入」")
        }
    }

    func testContentRewritesAndEmphasisAreNotAutoAdded() async throws {
        let cases = [("we had a meeting today about the budget", "we had a workshop today about the budget",
                      "We ran two workshops last week."),
                     ("please check the invoice before Friday", "please check the receipt before Friday", "keep all receipts"),
                     ("this is important for the launch", "this is IMPORTANT for the launch", "an important detail"),
                     ("send the demo to the label", "send the DEMO to the label", "the demo sounds great"),
                     ("the project plan is ready for review", "the Project Plan is ready for review",
                      "Can you update the project plan?")]
        for (inserted, edited, later) in cases {
            let context = try IsolatedContext.make(); defer { context.tearDown() }
            let prefs = AppPreferences(isolation: context)
            let before = deliver(later, prefs)
            _ = await editAndSend(prefs, inserted: inserted, edited: edited)
            XCTAssertEqual(prefs.dictionary, [:], "\(inserted) → \(edited)")
            XCTAssertEqual(deliver(later, prefs), before)
        }
    }

    /// verifier 重現：本版 Mac 學到 UTUVO（AUTO）上傳 iCloud，舊版用戶端讀成手動再寫回，之後兩邊都更新到這一版。
    /// 以前 10 次輪流同步寫了 10 次 iCloud（Auto 標籤一直閃）；現在最多寫一次就收斂。
    func testCloudSyncConvergesAfterALegacyRoundTrip() throws {
        let ca = try IsolatedContext.make(), cb = try IsolatedContext.make()
        defer { ca.tearDown(); cb.tearDown() }
        let mac = AppPreferences(isolation: ca), other = AppPreferences(isolation: cb)
        let cloud = CountingCloud()
        mac.learn(fromEdits: [correction("Utuvo", "UTUVO")])
        XCTAssertEqual(mac.dictionaryAutoTerms, ["UTUVO"])
        DictionaryCloud.sync(mac, store: cloud)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cloud.blob)) as? [String: Any])
        var entries = try XCTUnwrap(legacy["entries"] as? [String: [String: Any]])
        for key in entries.keys { entries[key]?.removeValue(forKey: "source") }
        var stripped = legacy; stripped["entries"] = entries
        other.mergeDictionary(try DictionarySync.decode(JSONSerialization.data(withJSONObject: stripped)))
        let start = cloud.writes
        var sources: [DictionarySync.Source] = []
        for _ in 1...5 {
            DictionaryCloud.sync(other, store: cloud)
            sources.append(try XCTUnwrap(DictionarySync.decode(XCTUnwrap(cloud.blob)).source(of: "UTUVO")))
            DictionaryCloud.sync(mac, store: cloud)
            sources.append(try XCTUnwrap(DictionarySync.decode(XCTUnwrap(cloud.blob)).source(of: "UTUVO")))
        }
        XCTAssertLessThanOrEqual(cloud.writes - start, 1, "收斂後不再寫 iCloud")
        XCTAssertEqual(Set(sources.dropFirst()), [sources.last!], "來源不再來回跳")
        XCTAssertEqual(mac.dictionarySync.entries["UTUVO"], other.dictionarySync.entries["UTUVO"], "兩邊一樣")
    }

    private final class CountingCloud: DictionaryCloudStore {
        var blob: Data?
        var writes = 0
        func data(forKey key: String) -> Data? { blob }
        func set(_ data: Data, forKey key: String) { blob = data; writes += 1 }
    }

    func testToastAddAcceptsOnlyTheSuggestionsItShows() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let prefs = AppPreferences(isolation: context)
        let found = [correction("今天", "明天"), correction("週一", "週二"), correction("會議室", "大廳"),
                     correction("三點", "四點"), correction("十人", "八人")]
        let result = prefs.learn(fromEdits: found)
        XCTAssertEqual(result.suggested.count, 5)
        let content = try XCTUnwrap(LearnedWordToast.content(for: result, zh: true))
        XCTAssertEqual(content.lines.count, LearnedWordToast.maxLines)
        XCTAssertEqual(content.suggestions.count, LearnedWordToast.maxLines)
        XCTAssertEqual(content.lines, content.suggestions.map { "\($0.from) → \($0.to)" }, "按鈕作用的就是列出來的那幾筆")
        XCTAssertEqual(content.note, "另有 2 個建議在設定的「個人字典」")
        LearnedWordToast.accept(content, preferences: prefs)   // 提示卡「加入」做的事
        XCTAssertEqual(Set(prefs.dictionary.keys), Set(content.suggestions.map(\.from)), "沒列出來的不能被加進字典")
        let hidden = found.filter { !content.suggestions.contains($0) }
        XCTAssertEqual(Set(prefs.dictionarySuggestions), Set(hidden), "沒列出來的留在設定頁的建議清單")
        XCTAssertEqual(deliver("那就約今天。改到週一，好嗎", prefs), "那就約今天。改到週一，好嗎")

        let other = try IsolatedContext.make(); defer { other.tearDown() }
        let p2 = AppPreferences(isolation: other)
        let r2 = p2.learn(fromEdits: found)
        let c2 = try XCTUnwrap(LearnedWordToast.content(for: r2, zh: true))
        LearnedWordToast.ignore(c2, preferences: p2)          // 提示卡「忽略」
        XCTAssertEqual(Set(p2.dictionarySuggestions), Set(found.filter { !c2.suggestions.contains($0) }),
                       "忽略也只動列出來的")
    }
}
