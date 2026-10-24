import XCTest
@testable import UTUVOTypeCore

/// FX-5（2026-10-22）：英文專名修正不准把常用英文字換成別的詞。
///
/// 修之前把 english-words.txt 前兩萬個字逐一丟進修正器：舊 Mac 的 16 個詞改到 100 個（glad／cloud→Claude、apply→Apple），
/// Android Dictation.clean 與 iOS 用的整包 ai 改到 295 個（phone→iPhone、shop→Zhipu、stock→SDK、types→Typeless、
/// commits→commit），三包全開 351 個。每個人的第一次貼上都會碰到。
/// Kotlin 鏡像：android/core/.../LatinCommonWordTest.kt；兩邊的逐字輸出另由 GoldenExportTests 的 latin-names.json 對。
final class LatinCommonWordTests: XCTestCase {
    private let ai = LatinTermSets.ai
    private let allPacks = LatinTermSets.aiTwAudio

    // MARK: - 單一個常用英文字不換成別的詞

    func testTicketSentencesStayAsSpoken() {
        for sentence in ["I'm glad the cloud sync works",
                         "我的 phone 拿去 shop 修了，這些 types 的 stock 都還在",
                         "commits are pushed",
                         "apply the claim to the common gold"] {
            XCTAssertEqual(LatinNameFixer.fix(sentence, terms: ai), sentence, "整包 ai")
            XCTAssertEqual(LatinNameFixer.fix(sentence, terms: allPacks), sentence, "三包全開")
            XCTAssertEqual(LatinNameFixer.fix(sentence, terms: LatinTermSets.oldMac), sentence, "舊 Mac 16 詞")
        }
    }

    /// 兩萬名以外、35 級以內的常用字（只護前兩萬行時這些照樣被改：nineteen→Notion、metering→mastering、Christmas→Cohere stems）。
    func testLongerCommonWordsBeyondTheFirst20kAreAlsoLeftAlone() {
        for word in ["nineteen", "metering", "partials", "timeless", "Christmas", "telegraph", "commute", "whispers",
                     "goggles", "discreet", "emission", "confession", "fostering", "wanderer", "innuendo"] {
            XCTAssertEqual(LatinNameFixer.fix("我說 \(word) 了", terms: allPacks), "我說 \(word) 了", word)
        }
    }

    /// 常用字本身不切開（Christmas 曾被切成 Cohere＋stems、confession 切成 Canva＋session）。
    func testCommonWordIsNotSplitIntoTerms() {
        XCTAssertEqual(LatinNameFixer.fix("Christmas", terms: allPacks), "Christmas")
        XCTAssertEqual(LatinNameFixer.fix("confession", terms: ai), "confession")
        // 不是英文字的黏在一起照切（實機 AppleNVidia、clotecoateGLMKimi）。
        XCTAssertEqual(LatinNameFixer.fix("AppleNVidia", terms: ai), "Apple NVIDIA")
    }

    /// 同一個字只差大小寫照修（iphone→iPhone 本來就不是常用字；RADAR 是常用字 radar 的特殊寫法）；
    /// 但另一個常用字（reader）不能被拉過去，不是英文字的（rader）照修。
    func testCaseOnlyFixOfTheSameCommonWordStillApplies() {
        XCTAssertTrue(LatinNameFixer.isCommonEnglishWord("radar"))
        XCTAssertEqual(LatinNameFixer.fix("打開 radar", terms: ["RADAR"]), "打開 RADAR")
        XCTAssertEqual(LatinNameFixer.fix("打開 rader", terms: ["RADAR"]), "打開 RADAR")
        XCTAssertEqual(LatinNameFixer.fix("打開 reader", terms: ["RADAR"]), "打開 reader")
        XCTAssertEqual(LatinNameFixer.fix("我的 iphone", terms: ai), "我的 iPhone")
        XCTAssertEqual(LatinNameFixer.fix("chatgpt 跟 openai", terms: ai), "ChatGPT 跟 OpenAI")
    }

    func testCommonWordCheckIsSingleTokenOnly() {
        XCTAssertTrue(LatinNameFixer.isCommonEnglishWord("Cloud"))
        XCTAssertTrue(LatinNameFixer.isCommonEnglishWord("co-op"))
        XCTAssertFalse(LatinNameFixer.isCommonEnglishWord("cloud code"), "多字詞不在此限")
        XCTAssertFalse(LatinNameFixer.isCommonEnglishWord("Protus"))
        XCTAssertFalse(LatinNameFixer.isCommonEnglishWord("Gemeni"))
    }

    // MARK: - 多字詞與不是英文字的照舊

    func testPhrasesAndNonWordsKeepWorking() {
        let personal = ["DAMI music"] + BuiltInVocabulary.productNames
        let on = personal + allPacks
        XCTAssertEqual(LatinNameFixer.fix("更新 Protus", terms: on), "更新 Pro Tools")
        XCTAssertEqual(LatinNameFixer.fix("我用 Dolbe Edmos 混", terms: on), "我用 Dolby Atmos 混")
        XCTAssertEqual(LatinNameFixer.fix("我在 Darmy Music 上班", terms: on), "我在 DAMI music 上班")
        XCTAssertEqual(LatinNameFixer.fix("用 Utuvo Type 打字", terms: on), "用 UTUVO Type 打字")
        XCTAssertEqual(LatinNameFixer.fix("這首要做 Special Audio 版本", terms: on), "這首要做 Spatial Audio 版本")
        XCTAssertEqual(LatinNameFixer.fix("我在測試 Gemeni 的東西", terms: on), "我在測試 Gemini 的東西")
        XCTAssertEqual(LatinNameFixer.fix("問一下 chat gpt", terms: on), "問一下 ChatGPT")
        XCTAssertEqual(LatinNameFixer.fix("Cloud coat", terms: on), "Claude Code", "兩個常用字分開聽到＝多字詞，照比對")
        // 音訊包關著：Special Audio 不動（同 BuiltInVocabularyTests）。
        let off = personal + LatinTermSets.latin(BuiltInVocabulary.enabledTerms(["ai", "tw"]))
        XCTAssertEqual(LatinNameFixer.fix("這首要做 Special Audio 版本", terms: off), "這首要做 Special Audio 版本")
    }

    /// 「Logic Pro」聽成「Largec Pro」「Large C Pro」（segments_verified s4 的實際辨識稿）：後字 Pro 對上、前字差 2，
    /// 整串比的上限不夠，修之前一直沒修到。用兩字詞的後字當錨照修；前面那段是常用字的（lark Pro、large Pro）、
    /// 智慧整理寫的、音訊包關著的都不動。
    func testLogicProMishearingsAreFixedOnTheSpeechPath() {
        let on = ["DAMI music"] + BuiltInVocabulary.productNames + allPacks
        XCTAssertEqual(LatinNameFixer.fix("我用 Largec Pro 混", terms: on), "我用 Logic Pro 混")
        XCTAssertEqual(LatinNameFixer.fix("我用 Large C Pro 混", terms: on), "我用 Logic Pro 混")
        XCTAssertEqual(LatinNameFixer.fix("Largec Pro會出的音檔", terms: on), "Logic Pro會出的音檔")
        for kept in ["我用 Logic Pro 混", "這是 lark Pro 版", "這是 large Pro 版", "我用 Mac Pro 混", "這組 power tools 很好用"] {
            XCTAssertEqual(LatinNameFixer.fix(kept, terms: on), kept)
        }
        // 錨點規則放寬到距離 2 時，一般片語裡骨架不同的字不能被拉走（第一版實測會換：logins Pro→Logic Pro、
        // David music→DAMI music、alpine music→Apple Music、Paris Tools→Pro Tools、Tahoe Peak→True Peak）。
        for kept in ["logins Pro", "Louis Pro", "Lagos Pro", "David music", "alpine music", "Paris Tools", "Utah Type",
                     "Tahoe Peak", "mini Bites"] {
            XCTAssertEqual(LatinNameFixer.fix("我說 \(kept) 這個", terms: on), "我說 \(kept) 這個")
        }
        XCTAssertEqual(LatinNameFixer.fix("我用 Largec Pro 混", terms: on, source: .cleanup), "我用 Largec Pro 混", "只限辨識稿")
        let off = ["DAMI music"] + BuiltInVocabulary.productNames + LatinTermSets.latin(BuiltInVocabulary.enabledTerms(["ai", "tw"]))
        XCTAssertEqual(LatinNameFixer.fix("我用 Largec Pro 混", terms: off), "我用 Largec Pro 混", "音訊包關著")
    }

    // MARK: - 個人字典的明確替換照樣套

    /// 使用者自己寫「cloud→Claude」：字典那一關照換（修正器不先把 cloud 拉走，字典才對得到）。
    func testExplicitPersonalDictionaryEntryStillApplies() {
        let sentence = "I'm glad the cloud sync works"
        let withEntry = Normalizer(options: NormalizerOptions(dictionary: ["cloud": "Claude"], latinTerms: ai))
        XCTAssertEqual(withEntry.normalize(sentence).cleaned, "I'm glad the Claude sync works")
        XCTAssertEqual(withEntry.applyVocabulary(sentence), "I'm glad the Claude sync works")
        let plain = Normalizer(options: NormalizerOptions(latinTerms: ai))
        XCTAssertEqual(plain.normalize(sentence).cleaned, sentence)
        // 舊行為的另一個受害者：字典 glad→GLaDOS，修正器先把 glad 換成 Claude，字典就對不到了。
        let glados = Normalizer(options: NormalizerOptions(dictionary: ["glad": "GLaDOS"], latinTerms: ai))
        XCTAssertEqual(glados.normalize(sentence).cleaned, "I'm GLaDOS the cloud sync works")
    }

    // MARK: - 常用字全表掃過：每一組詞都 0 個換成別的詞

    /// 工單量的是 english-words.txt 前兩萬行；這裡掃整個 35 級（前 49,877 行，前兩萬行在裡面）。
    /// 只允許「同一個字只差大小寫」。
    func testNoCommonWordIsRewrittenToAnotherTermInAnyTermSet() throws {
        let words = try LatinTermSets.englishWords()
        let common = words[0..<CommonEnglishWords.rankCutoff]
        for set in LatinTermSets.sweepSets {
            let changed = LatinTermSets.sweep(common, terms: set.terms).filter { !$0.caseOnly }
            XCTAssertEqual(changed.count, 0, "\(set.name)：" + changed.prefix(20).map { "\($0.word)→\($0.output)" }.joined(separator: "、"))
        }
    }

    // MARK: - 常用字表：Swift 與 Kotlin 同一份、跟來源詞表一致

    func testWordListMatchesSourceAndKotlinCopy() throws {
        let words = try LatinTermSets.englishWords()
        let starts = (1..<words.count).filter { words[$0].count < words[$0 - 1].count }
        XCTAssertEqual(starts.count, 4, "english-words.txt 應該是 10/20/35/40/50 五級")
        XCTAssertEqual(CommonEnglishWords.rankCutoff, starts[2], "取到 35 級的最後一行")
        let expected = Set(words[0..<starts[2]].filter { $0.allSatisfy(\.isLatinLetter) }.map { $0.lowercased() })
        XCTAssertEqual(CommonEnglishWords.words, expected, "跟 english-words.txt 不一致：重跑 scripts/build-common-english-words.py")
        XCTAssertEqual(CommonEnglishWords.count, expected.count)
        for word in ["glad", "cloud", "phone", "shop", "stock", "types", "commits", "nineteen", "metering"] {
            XCTAssertTrue(CommonEnglishWords.contains(word), word)
        }
        for nonWord in ["protus", "gemeni", "grook", "sesion", "utuvo", "darmy"] {
            XCTAssertFalse(CommonEnglishWords.contains(nonWord), nonWord)
        }

        let kotlin = try String(contentsOfFile: TestSupport.repoRoot()
                                + "/android/core/src/main/kotlin/com/utuvo/type/core/CommonEnglishWords.kt", encoding: .utf8)
        let body = try XCTUnwrap(kotlin.range(of: "arrayOf(")).upperBound
        let kotlinChunks = kotlin[body...].components(separatedBy: "\"\"\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map { $0.element.split(whereSeparator: \.isWhitespace).map(String.init) }
        XCTAssertEqual(kotlinChunks, CommonEnglishWords.chunks.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) },
                       "Kotlin CommonEnglishWords.kt 跟 Swift 不同：重跑 scripts/build-common-english-words.py")
        XCTAssertTrue(kotlin.contains("const val RANK_CUTOFF = \(CommonEnglishWords.rankCutoff)"))
        XCTAssertTrue(kotlin.contains("const val COUNT = \(CommonEnglishWords.count)"))
    }
}

/// 掃詞用的幾組詞（LatinCommonWordTests 與 GoldenExportTests 共用）。
enum LatinTermSets {
    /// 舊 Mac 的 16 個（3415792 以前的 VocabularyPacks.builtInLatinTerms）。
    static let oldMac = ["Gemini", "Google Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code",
                         "Anthropic", "Perplexity", "Apple", "NVIDIA", "MiniMax", "GLM", "Kimi", "UTUVO", "UTUVO Type"]
    static let allIDs: Set<String> = ["ai", "tw", "audio"]

    /// 只留含拉丁字母的詞（Android `latinTermsForFixer` 同規則）。
    static func latin(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { t in t.contains(where: \.isLatinLetter) && seen.insert(t).inserted }
    }

    /// Android Dictation.clean／iOS 在只開 ai 時的修正目標。
    static var ai: [String] { latin(BuiltInVocabulary.ai.terms) }
    /// 三包全開。
    static var aiTwAudio: [String] { latin(BuiltInVocabulary.enabledTerms(allIDs)) }

    static var sweepSets: [(name: String, terms: [String])] {
        [("oldMac16", oldMac),
         ("aiPack", ai),
         ("aiTwAudio", aiTwAudio),
         ("cleanedTextRule", Normalizer.latinTermsForCleanedText(personal: BuiltInVocabulary.productNames,
                                                                 packTerms: BuiltInVocabulary.enabledTerms(allIDs))),
         ("macDeterministic", latin(BuiltInVocabulary.productNames + BuiltInVocabulary.fixerTerms(allIDs)))]
    }

    static func englishWords() throws -> [String] {
        try String(contentsOfFile: TestSupport.repoRoot() + "/android/app/src/main/assets/english-words.txt", encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 每個字各自是一段（中間用全形逗號隔開，修正器不會把它們接成一串），一次跑完。
    static func sweep(_ words: ArraySlice<String>, terms: [String],
                      source: LatinNameFixer.TextSource = .speech) -> [(word: String, output: String, caseOnly: Bool)] {
        let out = LatinNameFixer.fix(words.joined(separator: "，"), terms: terms, source: source).components(separatedBy: "，")
        precondition(out.count == words.count, "掃詞對不上：\(out.count) vs \(words.count)")
        return zip(words, out).compactMap { word, output in
            word == output ? nil : (word, output, LatinNameFixer.plain(word) == LatinNameFixer.plain(output))
        }
    }
}
