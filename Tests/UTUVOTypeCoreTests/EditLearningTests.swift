import XCTest
@testable import UTUVOTypeCore

/// asr-vocab-4／delivery-learning-4：從修改學到的配對，哪些可以不經確認寫進字典。
final class EditLearningTests: XCTestCase {
    /// `packs`＝開著的詞庫包裡的英文詞（App 傳 `VocabularyPacks.latinTermsForFixer` 的內建詞＋seed）。
    private func decide(_ from: String, _ to: String, packs: Set<String> = []) -> EditLearning.Decision {
        EditLearning.decide(EditTracker.Correction(from: from, to: to), knownTerms: packs)
    }

    /// 2026-10-22 修補：中文硬替換要「至少改兩個字、每個都同音」。只改一個字的（元→圓＋山）key 是補鄰字湊的，只留建議。
    func testChineseHomophoneFixesBecomeReplacements() {
        XCTAssertEqual(decide("練係", "聯繫"), .replacement(from: "練係", to: "聯繫"))
        XCTAssertEqual(decide("城市", "程式"), .replacement(from: "城市", to: "程式"))
        XCTAssertEqual(decide("元山", "圓山"), .suggestion, "只改一個字")
        XCTAssertEqual(decide("除值", "儲值"), .suggestion, "只改一個字")
        XCTAssertEqual(decide("會出", "匯出"), .suggestion, "只改一個字")
        XCTAssertEqual(decide("母袋", "母帶"), .suggestion, "只改一個字")
    }

    func testChineseContentEditsAreOnlySuggestions() {
        XCTAssertEqual(decide("今天", "明天"), .suggestion, "讀音不同＝改主意，不是辨識錯字")
        XCTAssertEqual(decide("三點", "四點"), .suggestion, "數字不換")
        XCTAssertEqual(decide("他說", "她說"), .suggestion, "人稱代名詞同音也不換（替使用者猜性別）")
        XCTAssertEqual(decide("不要", "布要"), .suggestion, "否定詞不換")
        XCTAssertEqual(decide("機", "雞"), .suggestion, "單字全域替換會誤傷（同手機 CorrectionLearner 的 2–6 字）")
        XCTAssertEqual(decide("元山站前", "圓山站"), .suggestion, "字數不同")
        XCTAssertEqual(decide("小柏", "小潘"), .suggestion)
    }

    /// 改成詞庫包的詞（Pro Tools、Atmos）或品牌寫法（DAMI）、而且 LatinNameFixer 距離內：硬替換。
    func testEnglishNameFixesWithinTheFixerDistanceBecomeReplacements() {
        let packs: Set<String> = ["Pro Tools", "Atmos"]
        XCTAssertEqual(decide("Protus", "Pro Tools", packs: packs), .replacement(from: "Protus", to: "Pro Tools"))
        XCTAssertEqual(decide("Dummy Music", "DAMI music"), .replacement(from: "Dummy Music", to: "DAMI music"))
        XCTAssertEqual(decide("Atmus", "Atmos", packs: packs), .replacement(from: "Atmus", to: "Atmos"))
        XCTAssertEqual(decide("Damie", "DAMI"), .replacement(from: "Damie", to: "DAMI"))
        // 2026-10-22 修補：不在詞庫包、寫法也只是字首大寫的，只留建議（Stephen→Steven 會把兩個人合併）。
        XCTAssertEqual(decide("Protus", "Pro Tools"), .suggestion)
        XCTAssertEqual(decide("Atmus", "Atmos"), .suggestion)
        XCTAssertEqual(decide("Stephen", "Steven"), .suggestion)
        XCTAssertEqual(decide("Jemini", "Gemini", packs: ["Gemini"]), .replacement(from: "Jemini", to: "Gemini"))
    }

    func testCaseOnlyBrandFixIsVocabularyNotAReplacement() {
        // 只差大小寫的永遠不做硬替換；改後寫法有特色的加成詞彙，交給 LatinNameFixer 依寫法處理。
        XCTAssertEqual(decide("Utuvo", "UTUVO"), .vocabulary("UTUVO"))
        XCTAssertEqual(decide("iphone", "iPhone"), .vocabulary("iPhone"))
        XCTAssertEqual(LatinNameFixer.fix("我在用 Utuvo 打字", terms: ["UTUVO"]), "我在用 UTUVO 打字",
                       "詞彙模式的 UTUVO 就修得到 Utuvo")
        XCTAssertEqual(LatinNameFixer.fix("the tool menu", terms: ["Tool"]), "the tool menu",
                       "寫法不特別的詞不會被詞彙改大小寫")
    }

    func testEnglishThatFailsTheNameFilterIsVocabularyOrSuggestion() {
        XCTAssertEqual(decide("派森", "Python", packs: ["Python"]), .vocabulary("Python"), "讀音判斷不了：只加詞彙、不做替換")
        XCTAssertEqual(decide("派森", "Python"), .suggestion, "Python 不在詞庫包、寫法也不像品牌：只留建議")
        XCTAssertEqual(decide("tool", "Tool"), .suggestion, "只差大小寫、寫法也不特別")
        XCTAssertEqual(decide("Session", "session"), .suggestion)
        XCTAssertEqual(decide("meeting", "call"), .suggestion, "改成常用英文字＝改內容")
        XCTAssertEqual(decide("Zoom", "Teams 來"), .suggestion, "夾中文的不是英文專名")
    }

    func testFilters() {
        XCTAssertTrue(EditLearning.isHomophoneFix(from: "元山", to: "圓山"))
        XCTAssertFalse(EditLearning.isHomophoneFix(from: "元山", to: "元山"))
        XCTAssertFalse(EditLearning.isHomophoneFix(from: "A元", to: "A圓"), "只看全中文")
        XCTAssertFalse(EditLearning.isHomophoneFix(from: "一二三四五六七", to: "一二三四五六七"))
        XCTAssertTrue(EditLearning.isLatinNameFix(from: "Protus", to: "Pro Tools"))
        XCTAssertFalse(EditLearning.isLatinNameFix(from: "meeting", to: "Zoom"))
        XCTAssertTrue(EditLearning.isVocabularyTerm("DAMI music"))
        XCTAssertFalse(EditLearning.isVocabularyTerm("call"), "常用英文字")
        XCTAssertFalse(EditLearning.isVocabularyTerm("圓山"))
        XCTAssertFalse(EditLearning.isVocabularyTerm("X"))
    }

    // MARK: - 2026-10-22 修補（verifier mac-learning2）

    /// 單字修改（在→再、的→得、美→梅）：EditTracker 會補一個鄰字湊成兩個字，不能因此變成硬替換——
    /// 「在說→再說」學進去，之後「他們還在說」就被改成「還再說」；手機的 CorrectionLearner 也只學使用者自己改的 ≥2 字。
    func testSingleCharacterChineseChangesNeverBecomeReplacements() {
        let edits = [("好，那我們下次在說", "好，那我們下次再說"), ("那我們明天在想辦法吧", "那我們明天再想辦法吧"),
                     ("他跑的很快", "他跑得很快"), ("明天跟小美吃飯", "明天跟小梅吃飯"), ("我們在元山見面", "我們在圓山見面")]
        for (inserted, edited) in edits {
            let found = EditTracker.corrections(inserted: inserted, current: edited)
            XCTAssertFalse(found.isEmpty, inserted)
            for c in found {
                XCTAssertEqual(EditLearning.decide(c), .suggestion, "\(c.from)→\(c.to)")
            }
        }
        XCTAssertEqual(decide("在說", "再說"), .suggestion)
        XCTAssertEqual(decide("的很", "得很"), .suggestion)
        XCTAssertEqual(decide("美吃", "梅吃"), .suggestion)
    }

    func testTwoChangedHomophoneCharactersAreStillAReplacement() {
        XCTAssertEqual(decide("練係", "聯繫"), .replacement(from: "練係", to: "聯繫"), "兩個字都改、都同音＝辨識錯字")
        XCTAssertEqual(EditLearning.changedCharacters(from: "元山", to: "圓山"), 1)
        XCTAssertEqual(EditLearning.changedCharacters(from: "練係", to: "聯繫"), 2)
        XCTAssertEqual(EditLearning.changedCharacters(from: "元山", to: "圓山站"), 2)
    }

    /// 兩個普通英文名字／單字互換（Stephen→Steven、meeting→workshop）、強調用的大寫（important→IMPORTANT）、
    /// 片語改成標題大寫（project plan→Project Plan）都是改內容：只留建議，不自動加。
    func testOrdinaryEnglishWordAndNameSwapsAreNotAutoAdded() {
        for (from, to) in [("Stephen", "Steven"), ("Katherine", "Catherine"), ("Allen", "Allan"), ("Erik", "Eric"),
                           ("meeting", "workshop"), ("invoice", "receipt"), ("important", "IMPORTANT"),
                           ("urgent", "URGENT"), ("project plan", "Project Plan"), ("Swift", "SwiftUI 很")] {
            XCTAssertEqual(decide(from, to), .suggestion, "\(from)→\(to)")
        }
    }

    /// 自動加只給「改成詞庫包的詞」或「寫法像品牌」（字中間有大寫、或不是常用英文字的全大寫縮寫）。
    func testBrandCasedTargetsStillAutoAdd() {
        XCTAssertEqual(decide("Utuvo", "UTUVO"), .vocabulary("UTUVO"))
        XCTAssertEqual(decide("Damie", "DAMI"), .replacement(from: "Damie", to: "DAMI"))
        XCTAssertEqual(decide("iphone", "iPhone"), .vocabulary("iPhone"))
        XCTAssertEqual(decide("Dummy Music", "DAMI music"), .replacement(from: "Dummy Music", to: "DAMI music"))
    }

    /// 2026-10-22 wave2 整合（verify2:mac-learning2 high）：原字是單獨的常用英文字時，改成品牌寫法也不做硬替換
    /// （phone→iPhone 學進去之後，每個 phone 都會被改掉）。最多只留建議，跟 LatinNameFixer 的常用字保護（FX-5）同一份字表。
    func testCommonEnglishSourceWordsAreNeverAutoReplaced() {
        let packs: Set<String> = ["iPhone", "iMessage", "iCloud", "LinkedIn", "Claude", "Facebook"]
        for (from, to) in [("phone", "iPhone"), ("message", "iMessage"), ("cloud", "iCloud"), ("linked in", "LinkedIn"),
                           ("cloud", "Claude"), ("glad", "Claude"), ("face book", "Facebook"), ("dummy music", "DAMI music")] {
            XCTAssertEqual(decide(from, to), .suggestion, "\(from)→\(to)")
            XCTAssertEqual(decide(from, to, packs: packs), .suggestion, "\(from)→\(to)（詞在詞庫包裡）")
        }
        XCTAssertEqual(decide("iphone", "iPhone"), .vocabulary("iPhone"), "只差大小寫的品牌寫法照舊加成詞彙")
        XCTAssertEqual(decide("Linkdin", "LinkedIn", packs: packs), .replacement(from: "Linkdin", to: "LinkedIn"),
                       "原字不是常用字的拼法錯字照舊硬替換")
        XCTAssertEqual(decide("Dummy Music", "DAMI music"), .replacement(from: "Dummy Music", to: "DAMI music"),
                       "每個字都大寫開頭的片語像聽錯的名字，照舊硬替換")
    }

    func testBrandCasingAndCommonWords() {
        XCTAssertTrue(EditLearning.hasBrandCasing("UTUVO"))
        XCTAssertTrue(EditLearning.hasBrandCasing("DAMI music"))
        XCTAssertTrue(EditLearning.hasBrandCasing("iPhone"))
        XCTAssertTrue(EditLearning.hasBrandCasing("ChatGPT"))
        XCTAssertFalse(EditLearning.hasBrandCasing("IMPORTANT"), "全大寫的常用字＝強調")
        XCTAssertFalse(EditLearning.hasBrandCasing("OK"))
        XCTAssertFalse(EditLearning.hasBrandCasing("Steven"))
        XCTAssertFalse(EditLearning.hasBrandCasing("Project Plan"), "每個字只有字首大寫")
        XCTAssertFalse(EditLearning.hasBrandCasing("workshop"))
        XCTAssertFalse(EditLearning.hasBrandCasing("UTUVO", isCommonWord: { _ in true }), "常用字判斷可以換（App 接系統字典）")
        XCTAssertTrue(EditLearning.isCommonEnglishWord("important"))
        XCTAssertTrue(EditLearning.isCommonEnglishWord("URGENT"))
        XCTAssertTrue(EditLearning.isCommonEnglishWord("code"), "LatinNameFixer.commonWords 也算")
        XCTAssertFalse(EditLearning.isCommonEnglishWord("utuvo"))
        XCTAssertFalse(EditLearning.isCommonEnglishWord("dami"))
        XCTAssertEqual(decide("demo", "DEMO"), .vocabulary("DEMO"),
                       "core 內建表只有 SCOWL 前兩級（demo 在第 40 級）；App 另外接系統字典擋掉（見 EditLearningAppTests）")
        XCTAssertEqual(EditLearning.decide(.init(from: "demo", to: "DEMO"), isCommonWord: { $0.lowercased() == "demo" }), .suggestion)
    }

    /// 內建常用字表是從 repo 的英文詞表產生的（scripts/build-english-common-words.py），兩邊要一致。
    func testEmbeddedCommonWordsMatchTheRepoWordList() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../android/app/src/main/assets/english-words.txt").standardized
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "android/ 不在這個 checkout（開源版）")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        var expected = Set<String>(), level = 0, previous = 0
        for w in lines {
            if w.count < previous { level += 1; if level >= 2 { break } }   // 字長變短＝SCOWL 下一級
            previous = w.count
            if w.allSatisfy({ $0.isASCII && $0.isLetter }) { expected.insert(w.lowercased()) }
        }
        XCTAssertEqual(EnglishCommonWords.words, expected)
        XCTAssertEqual(EnglishCommonWords.count, expected.count)
    }
}
