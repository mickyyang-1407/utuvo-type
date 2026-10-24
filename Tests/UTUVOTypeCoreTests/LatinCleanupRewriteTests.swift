import XCTest
@testable import UTUVOTypeCore

/// W2-1 verifier（2026-10-22）：智慧整理通過把關後補套「英文專名＋個人字典」（`Normalizer.applyVocabulary`），
/// 不能把整理寫對的文字改壞，也要冪等。四類：
/// 1. 開頭是數字的個人詞會疊字（3Coins→33Coins→333Coins、7-Eleven→7-7-Eleven、password→1Password）；
/// 2. 個人單字詞把正確的英文拉走（cloud→iCloud、codec／codecs→Codex、Daisy→Daiso、Mickey→Micky、Martin→Morten、
///    perplexing→Perplexity、Tone Master→Tonmeister、glad／called→Claude），模糊比對還搶在字典的明確規則前面；
/// 3. 開 audio 包時 protocols→Pro Tools；
/// 4. 一般名詞的小寫與複數被改成包內寫法（vibe coding→Vibe Coding、true peak、spatial audio、UTUVO Types→UTUVO Type）。
/// Kotlin 鏡像：android/core/.../LatinCleanupRewriteTest.kt；整份語料另由 GoldenExportTests 的 vocabulary-apply.json 逐字對。
final class LatinCleanupRewriteTests: XCTestCase {
    /// 字典：verifier 用的真實字典形狀（identity 條目、詞彙模式空輸出、開頭是數字的詞），只放拉丁字母條目。
    static let dictionary: [String: String] = [
        "iCloud": "iCloud", "Codex": "", "Daiso": "", "Perplexity": "", "Tonmeister": "", "Claude": "", "Micky": "",
        "Morten": "", "Eva": "", "Mix Bites": "", "DAMI music": "", "UTUVO Type": "", "3Coins": "3Coins",
        "1Password": "", "7-Eleven": "",
    ]

    /// 個人詞（Mac／Android `personalTerms`：有輸出用輸出、空的用 key；照 key 排）。
    static func personal(_ dictionary: [String: String]) -> [String] {
        dictionary.sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) }
            .map { $0.value.isEmpty ? $0.key : $0.value }
    }
    static var personal: [String] { personal(dictionary) }

    /// 智慧整理後補套的英文專名目標（同 Mac `VocabularyPacks.latinTermsForCleanedText`）。
    static func cleanedTerms(_ dictionary: [String: String], packs: Set<String>) -> [String] {
        Normalizer.latinTermsForCleanedText(personal: personal(dictionary) + BuiltInVocabulary.productNames,
                                            packTerms: BuiltInVocabulary.enabledTerms(packs))
    }
    /// ai、tw、audio 全開。
    static var cleanedTerms: [String] { cleanedTerms(dictionary, packs: ["ai", "tw", "audio"]) }

    /// 第一次貼上（本機整理版）的英文專名目標：個人詞＋產品名＋開著的包全部（Android Dictation.clean 同形狀）。
    static func speechTerms(_ dictionary: [String: String], packs: Set<String>) -> [String] {
        var seen = Set<String>()
        return (personal(dictionary) + BuiltInVocabulary.productNames + BuiltInVocabulary.enabledTerms(packs))
            .filter { t in t.contains(where: { $0.isASCII && $0.isLetter }) && seen.insert(t).inserted }
    }
    static var speechTerms: [String] { speechTerms(dictionary, packs: ["ai", "tw", "audio"]) }

    /// 字典有明確規則（常用字當來源的 cloud→Claude、聽錯的 Jemini→Gemini 2.5、中文 key）的句子。
    static let ruleSentences = ["我在用 Jemini 跟 cloud", "我們的 cloud storage 滿了。", "The cloud version is better.",
                                "1. 用優土佛 Type 匯出\n2. 更新 Protus"]
    static let ruleDictionary: [String: String] = [
        "Claude": "", "Micky": "", "Morten": "", "DAMI music": "", "UTUVO Type": "", "Tonmeister": "", "Eva": "",
        "cloud": "Claude", "Jemini": "Gemini 2.5", "優土佛": "UTUVO",
    ]

    /// Kotlin 逐字對的幾組設定（GoldenExportTests → vocabulary-apply.json）。
    static var goldenSets: [(name: String, dictionary: [String: String], latinTerms: [String], speechTerms: [String])] {
        [("real-like", dictionary, cleanedTerms, speechTerms),
         ("rules-ai-tw", ruleDictionary, cleanedTerms(ruleDictionary, packs: ["ai", "tw"]), speechTerms(ruleDictionary, packs: ["ai", "tw"])),
         ("products-default", [:], cleanedTerms([:], packs: BuiltInVocabulary.defaultOnIDs),
          speechTerms([:], packs: BuiltInVocabulary.defaultOnIDs))]
    }

    /// 整理寫對的句子：補套前後、套兩次都要一字不差（verifier 語料，去掉 icloud→iCloud 那句大小寫修正）。
    static let correctCleanedText = [
        "我在 DAMI music 用 UTUVO Type 寫歌詞。",
        "這首歌要交 Dolby Atmos 的 ADM BWF，還有 stereo 的 AIFF。",
        "明天把 stems 匯出成 AIFF，再丟到 Pro Tools 裡混。",
        "這個 protocol 跟舊版不相容，要重新 apply。",
        "這兩個 protocols 不相容。",
        "我用 Logic Pro 開 session，再 commit 到 repo。",
        "我的 phone 拿去 shop 修了，這些 types 的 stock 都還在。",
        "I'm glad the cloud sync works.",
        "I'm glad it works.",
        "請把檔案上傳到 cloud，我等一下用 phone 看。",
        "你可以 apply 這個 patch 嗎？",
        "這版的 true peak 要控制在 -1 dBTP，LUFS 是 -14。",
        "我們先用 Claude Code 寫，再用 Claude 審。",
        "Tonmeister 這個職位在德國很常見。",
        "我是 Tonmeister，也是 DAMI music 的音樂總監。",
        "用 Spatial Audio 聽聽看 binaural 的版本。",
        "這個 spatial audio 混音有點太寬。",
        "Apple Music 的 Atmos 版本已經上架。",
        "我昨天在 Apple Store 買了 iPhone。",
        "UTUVO 的新產品叫 UTUVO Type。",
        "Utopia 這首歌的 stem 已經給你了。",
        "我想把所有的 types 都改成 enum。",
        "他是 vibe coding 的愛好者。",
        "Google Gemini 跟 ChatGPT 比起來哪個好？",
        "請 commit 之後 push 到 GitHub。",
        "Mickey Mouse 的配樂是誰做的？",
        "Micky 老師下週要上課。",
        "我今天跟 Eva 開會，討論 Mix Bites 的腳本。",
        "Morten 的 renderer 跟 Dolby 的不一樣。",
        "這個 logic 有問題，要重寫。",
        "Please send me the stems by Friday.",
        "The protocol says we should apply the patch before the commit.",
        "We stock AIFF and WAV files in the shop.",
        "The phone types are listed in the sheet.",
        "Can you check the true peak on the master?",
        "I mixed it in Pro Tools and mastered it in Logic Pro.",
        "Our product is called UTUVO Type, and it runs on Mac.",
        "The cloud version is better.",
        "我在用 Typeless，覺得 UTUVO Type 比較好。",
        "用 Waves 的 plugin 做 limiter。",
        "這個 glad 是什麼意思？",
        "先把 protocol buffer 定義好。",
        "這個 prototype 下週給你。",
        "我把 apply 的按鈕改成灰色。",
        "The stock market is down today.",
        "Fender 的 Tone Master 是一台吉他音箱。",
        "這個 codec 不支援 Atmos。",
        "AAC 跟 ALAC 這兩種 codecs 都可以。",
        "我在 3Coins 買了收納盒。",
        "密碼都存在 1Password 裡。",
        "我在 7-Eleven 買咖啡。",
        "這個 password 太短。",
        "我在 Daiso 買了收納盒。",
        "我女兒的同學叫 Daisy。",
        "照片都在 iCloud 裡。",
        "我把檔案放在 cloud 上。",
        "我覺得這個問題很 perplexing。",
        "我用 Perplexity 查資料。",
        "我用 Codex 寫程式。",
        "Daisy 跟 Daiso 不一樣。",
        "我們的 cloud storage 滿了。",
        "這是 UTUVO Type 的 types 設定。",
        "UTUVO Types 這個名字不好。",
        "Mix Bites 第三集要錄了。",
        "mix bites 是一個系列。",
        "他是 Eva 的同事 Evan。",
        "Martin 跟 Morten 是兩個人。",
    ]

    /// 整理寫錯、要修回使用者寫法的（segbench pn01／pn02／pn05＋verifier 那兩句）。
    static let misspelledCleanedText: [(String, String)] = [
        ("這次的 Dolby Atmos 混音是在 Pro Tools 上面做的，然後送到 Darmy Music 的教室去示範。",
         "這次的 Dolby Atmos 混音是在 Pro Tools 上面做的，然後送到 DAMI music 的教室去示範。"),
        ("我最近在研究 ToneMaster 的認證課程，北藝大的那門課用的是 Apple 的 Spatial Audio 工具。",
         "我最近在研究 Tonmeister 的認證課程，北藝大的那門課用的是 Apple 的 Spatial Audio 工具。"),
        ("Type 那個 app 在 Mac 上叫做 Utuvo Type，在手機上面也叫做 Utuvo Type，被搞混了。",
         "Type 那個 app 在 Mac 上叫做 UTUVO Type，在手機上面也叫做 UTUVO Type，被搞混了。"),
        ("DAMI Music 的 logo 要改。", "DAMI music 的 logo 要改。"),
        ("我在 Darmy Music 用 Utuvo Type 寫歌詞。", "我在 DAMI music 用 UTUVO Type 寫歌詞。"),
        ("更新 Protus 之後再匯出 stems。", "更新 Pro Tools 之後再匯出 stems。"),
    ]

    private func apply(_ text: String, _ dictionary: [String: String] = dictionary) -> String {
        Normalizer.applyVocabulary(text, dictionary: dictionary, latinTerms: Self.cleanedTerms)
    }

    // MARK: - 整理寫對的不動、寫錯的修回來、都冪等

    func testCorrectCleanedTextIsByteIdenticalAndIdempotent() {
        var changed: [String] = []
        for text in Self.correctCleanedText {
            let once = apply(text)
            if once != text { changed.append("\(text) → \(once)") }
            XCTAssertEqual(apply(once), once, "再套一次不變：\(text)")
        }
        XCTAssertEqual(changed, [], "整理寫對的被改了 \(changed.count) 句")
    }

    func testMisspelledUserTermsAreStillFixed() {
        for (input, expected) in Self.misspelledCleanedText {
            XCTAssertEqual(apply(input), expected)
            XCTAssertEqual(apply(expected), expected, "再套一次不變")
        }
    }

    // MARK: - 1. 開頭是數字的詞不疊字（第一次貼上也一樣）

    func testDigitLeadingTermsDoNotStack() {
        for text in ["我在 3Coins 買了收納盒。", "密碼都存在 1Password 裡。", "我在 7-Eleven 買咖啡。", "這個 password 太短。"] {
            XCTAssertEqual(apply(text), text)
            XCTAssertEqual(apply(apply(apply(text))), text, "套三次也不疊")
            XCTAssertEqual(LatinNameFixer.fix(text, terms: Self.speechTerms), text, "第一次貼上")
        }
        // 字母部分不是常用英文字（不靠常用字護欄）：「Qwen3」裡的 Qwen 以前會被換成整個 Qwen3 → Qwen33。
        for source in [LatinNameFixer.TextSource.speech, .cleanup] {
            XCTAssertEqual(LatinNameFixer.fix("我在測 Qwen3 的模型", terms: ["Qwen3"], source: source), "我在測 Qwen3 的模型")
            XCTAssertEqual(LatinNameFixer.fix("我在測 Qwen 的模型", terms: ["Qwen3"], source: source), "我在測 Qwen 的模型",
                           "不憑空補版本號")
        }
    }

    // MARK: - 2. 個人單字詞不把正確的英文拉走

    func testPersonalSingleWordTermsDoNotPullCorrectEnglish() {
        let cases = ["請把檔案上傳到 cloud，我等一下用 phone 看。", "I'm glad the cloud sync works.", "這個 codec 不支援 Atmos。",
                     "AAC 跟 ALAC 這兩種 codecs 都可以。", "我女兒的同學叫 Daisy。", "我覺得這個問題很 perplexing。",
                     "Fender 的 Tone Master 是一台吉他音箱。", "I'm glad it works.", "Our product is called UTUVO Type.",
                     "Mickey Mouse 的配樂是誰做的？", "Martin 跟 Morten 是兩個人。"]
        for text in cases { XCTAssertEqual(apply(text), text) }
        // 合成字典有 Claude／Micky／Morten 個人詞（verifier synth）也一樣。
        let synth = ["Claude": "", "Micky": "", "Morten": "", "DAMI music": "", "UTUVO Type": "", "Tonmeister": ""]
        let terms = Normalizer.latinTermsForCleanedText(personal: synth.keys.sorted() + BuiltInVocabulary.productNames,
                                                        packTerms: BuiltInVocabulary.enabledTerms(["ai", "tw"]))
        for text in ["I'm glad it works.", "Our product is called UTUVO Type.", "Mickey Mouse 的配樂是誰做的？",
                     "Martin 跟 Morten 是兩個人。", "Fender 的 Tone Master 是一台吉他音箱。"] {
            XCTAssertEqual(Normalizer.applyVocabulary(text, dictionary: synth, latinTerms: terms), text)
        }
    }

    /// 同樣的拼法，第一次貼上（辨識器逐字稿）照修：聽成兩個字的 Tone Master→Tonmeister、Coldex→Codex。
    func testSpeechPathStillFixesMishearings() {
        XCTAssertEqual(LatinNameFixer.fix("我是 Tone Master", terms: ["Tonmeister"]), "我是 Tonmeister")
        XCTAssertEqual(LatinNameFixer.fix("用 Coldex 寫", terms: ["Codex"]), "用 Codex 寫")
        // 整理寫的：駝峰黏字照修（pn02），正常寫法的單字不換成另一個單字詞。
        XCTAssertEqual(LatinNameFixer.fix("研究 ToneMaster", terms: ["Tonmeister"], source: .cleanup), "研究 Tonmeister")
        XCTAssertEqual(LatinNameFixer.fix("用 Coldex 寫", terms: ["Codex"], source: .cleanup), "用 Coldex 寫")
    }

    /// 字典有明確規則（Jemini→Gemini 2.5）：模糊比對不先把 Jemini 拉成 Gemini，字典那一關才對得到。
    func testExplicitDictionaryRuleBeatsFuzzyMatch() {
        let dict = ["Jemini": "Gemini 2.5", "cloud": "Claude"]
        let ai = LatinTermSets.latin(BuiltInVocabulary.enabledTerms(["ai"]))
        XCTAssertEqual(Normalizer.applyVocabulary("我在用 Jemini 跟 cloud", dictionary: dict, latinTerms: ai + ["iCloud"]),
                       "我在用 Gemini 2.5 跟 Claude")
        let speech = Normalizer(options: NormalizerOptions(dictionary: dict, latinTerms: ai + ["iCloud"]))
        XCTAssertTrue(speech.normalize("我在用 Jemini 跟 cloud").cleaned.contains("Gemini 2.5 跟 Claude"),
                      speech.normalize("我在用 Jemini 跟 cloud").cleaned)
        // 只有詞彙（輸出空字串）、或輸出等於自己的條目不算規則：照常修。
        let vocabOnly = Normalizer.applyVocabulary("我在 Darmy Music", dictionary: ["Darmy Music": ""],
                                                   latinTerms: ["DAMI music"])
        XCTAssertEqual(vocabOnly, "我在 DAMI music")
        XCTAssertEqual(Normalizer.dictionaryRuleKeys(["Jemini": "Gemini 2.5", "Atmos": "", "iCloud": "iCloud"]), ["Jemini"])
    }

    // MARK: - 3. 多字的包內詞不拉走常用字

    /// 兩個常用英文字的片語整串對得上詞（game／team／same／today／dumb music→DAMI music、live coding→Vibe Coding）：
    /// 修之前第一次貼上跟智慧整理後補套都會換（整串骨架或加權距離對得上）。字數一樣時要一個字對一個字對得上才換；
    /// Cloud coat→Claude Code、Special Audio→Spatial Audio、Darmy Music→DAMI music 照修。
    func testCommonTwoWordPhrasesAreNotPulledToTerms() {
        for text in ["我喜歡 game music。", "這是 team music。", "same music 也可以。", "today music 排行。", "dumb music",
                     "live coding 很好玩。", "selective Type 的設定", "claims Bites", "請輸入 access code", "這個 is code 嗎",
                     "這段 quality code 很乾淨", "這個我 could code 出來"] {
            XCTAssertEqual(apply(text), text)
            XCTAssertEqual(LatinNameFixer.fix(text, terms: Self.speechTerms), text, "第一次貼上")
        }
        XCTAssertEqual(LatinNameFixer.fix("Cloud coat", terms: Self.speechTerms), "Claude Code")
        XCTAssertEqual(LatinNameFixer.fix("我是 Tone Master", terms: Self.speechTerms), "我是 Tonmeister", "字數不同、同首字母的照修")
        XCTAssertEqual(LatinNameFixer.fix("這首要做 Special Audio 版本", terms: Self.speechTerms), "這首要做 Spatial Audio 版本")
        XCTAssertEqual(apply("這首要做 Special Audio 版本"), "這首要做 Spatial Audio 版本")
        XCTAssertEqual(apply("我在 Darmy Music 上課"), "我在 DAMI music 上課")
    }

    func testProtocolsIsNotPulledToProTools() {
        XCTAssertEqual(apply("這兩個 protocols 不相容。"), "這兩個 protocols 不相容。")
        XCTAssertEqual(LatinNameFixer.fix("這兩個 protocols 不相容。", terms: Self.speechTerms), "這兩個 protocols 不相容。")
    }

    // MARK: - 4. 一般名詞的小寫與複數

    func testLowercaseCommonNounsAndPluralsAreKept() {
        for text in ["他是 vibe coding 的愛好者。", "這版的 true peak 要控制在 -1 dBTP", "這個 spatial audio 混音有點太寬。",
                     "UTUVO Types 這個名字不好。", "mix bites 是一個系列。"] {
            XCTAssertEqual(apply(text), text)
        }
        // 複數在第一次貼上也不改回單數。
        XCTAssertEqual(LatinNameFixer.fix("UTUVO Types 這個名字不好", terms: Self.speechTerms), "UTUVO Types 這個名字不好")
        XCTAssertEqual(LatinNameFixer.fix("這些 GPTs 都很好用", terms: ["GPT"]), "這些 GPTs 都很好用")
        // 寫法本身特別的字照修（整理寫成 Utuvo、Dami 的）。
        XCTAssertEqual(apply("用 utuvo type 打字"), "用 UTUVO Type 打字")
        XCTAssertEqual(apply("在 Dami Music 上課"), "在 DAMI music 上課")
    }

    // MARK: - 字典順序（Swift 那邊 Dictionary 的順序每次都不一樣）

    /// 一樣長的兩個 key 重疊（a-b-c 裡的 a-b／b-c）：照 UTF-16 排（Kotlin `longestFirst` 的 thenBy），每次都一樣。
    /// 修之前只照長度排，一樣長的跟著 Dictionary 的順序走，每個 process（甚至每個容量）都可能不同。
    func testDictionaryKeysOfEqualLengthApplyInAFixedOrder() {
        var outputs = Set<String>()
        for capacity in [0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144] {
            var dict = [String: String](minimumCapacity: capacity)
            dict["b-c"] = "B"
            dict["a-b"] = "A"
            outputs.insert(Normalizer.applyDictionary("xx a-b-c yy", dict: dict))
            var reversed = [String: String](minimumCapacity: capacity)
            reversed["a-b"] = "A"
            reversed["b-c"] = "B"
            outputs.insert(Normalizer.applyDictionary("xx a-b-c yy", dict: reversed))
        }
        XCTAssertEqual(outputs, ["xx A-c yy"], "a-b 先（UTF-16 小的先），同 Kotlin")
    }
}
