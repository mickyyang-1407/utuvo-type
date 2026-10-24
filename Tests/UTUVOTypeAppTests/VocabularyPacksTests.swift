import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore
import Speech

/// 詞庫包 catalog decode + lazy load + 200 上限 + Latin seeds only。
/// 用 repo 內真實 `data/vocabulary/catalog.json`（透過 test bundle .copy 資源）。
final class VocabularyPacksTests: XCTestCase {

    func testMobileNamesAndLazyMetadata() throws {
        // asr-vocab-1（2026-10-22）：AI 名稱改成內建 ai 包的開關（預設開），不再寫死；所以這裡要把 ai 一起開。
        let terms = VocabularyPacks.latinTermsForFixer(personalValues: ["PersonalFixture"],
                                                       enabled: Set(VocabularyCatalog.Catalog.knownIDs).union(["ai"]))
        for term in ["Gemini", "ChatGPT", "Claude Code", "Perplexity", "PersonalFixture"] { XCTAssertTrue(terms.contains(term)) }
        XCTAssertTrue(VocabularyPacks.catalog.packs.allSatisfy { $0.terms == nil })
        XCTAssertLessThan(terms.count, 200)
    }

    func testASRHintsUseCanonicalPersonalTermsAndFairMetadataSeeds() {
        let enabled = Set(VocabularyCatalog.Catalog.knownIDs)
        let hints = VocabularyPacks.contextualHints(personal: ["bad-spelling": "CanonicalFixture"], enabled: enabled)
        XCTAssertEqual(hints.first, "CanonicalFixture")
        XCTAssertFalse(hints.contains("bad-spelling"))
        XCTAssertLessThanOrEqual(hints.count, 200)
        for pack in VocabularyPacks.enabledCatalogPacks(enabled: enabled) {
            XCTAssertTrue(pack.seedTerms.contains(where: hints.contains))
        }
    }

    /// W2-1 verifier（2026-10-22）：個人詞的順序照 key 排（同 Android `personalTermsInKeyOrder`）。
    /// 修之前用 Dictionary.map，順序每個 process 都不一樣；「Dami Music」「DAMI music」折成同一個寫法時修正器先到先得，
    /// 同一台 Mac 跑 6 次有 4 次輸出 Dami Music、2 次 DAMI music，也跟 Android 對不上。
    func testPersonalTermOrderIsFixedAndMatchesAndroid() {
        var orders = Set<[String]>(), outputs = Set<String>()
        for capacity in [0, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144] {
            for insertion in [["Dami Music", "DAMI music"], ["DAMI music", "Dami Music"]] {
                var dictionary = [String: String](minimumCapacity: capacity)
                for key in insertion { dictionary[key] = "" }
                orders.insert(VocabularyPacks.personalTerms(dictionary))
                let terms = VocabularyPacks.latinTermsForCleanedText(personal: dictionary, enabled: [])
                outputs.insert(Normalizer.applyVocabulary("我在 dami music 上課", dictionary: dictionary, latinTerms: terms))
                XCTAssertEqual(VocabularyPacks.latinTermsForFixer(personal: dictionary, enabled: []).prefix(2),
                               ["DAMI music", "Dami Music"])
            }
        }
        XCTAssertEqual(orders, [["DAMI music", "Dami Music"]], "照 key 的 code point 排：D-A 在 D-a 前面")
        XCTAssertEqual(outputs, ["我在 DAMI music 上課"])
    }

    /// asr-vocab-v2：輸出寫法留空的「詞彙」模式條目（從 iPhone／Android 同步、匯入的單詞）也要進 LatinNameFixer 詞表。
    func testVocabularyModeEntriesReachLatinFixer() {
        let terms = VocabularyPacks.latinTermsForFixer(personal: ["Atmos": "", "bad-spelling": "CanonicalFixture"], enabled: [])
        XCTAssertTrue(terms.contains("Atmos"))
        XCTAssertTrue(terms.contains("CanonicalFixture"))
        XCTAssertFalse(terms.contains("bad-spelling"), "有輸出寫法的用輸出寫法")
        XCTAssertFalse(terms.contains(""))
        XCTAssertEqual(LatinNameFixer.fix("我用 Atmus 混", terms: terms), "我用 Atmos 混")
        XCTAssertEqual(VocabularyPacks.personalTerms(["Atmos": "", "x": "X"]).sorted(), ["Atmos", "X"])
    }

    func testKnownIDs() {
        XCTAssertEqual(VocabularyCatalog.Catalog.knownIDs,
                       ["computing", "medicine", "finance", "law", "engineering", "music"])
    }

    func testCatalogDecodeFromTestBundle() throws {
        // 用 test bundle 拿 catalog.json
        let bundle = VocabularyPacks.resourceBundle
        let catalog = try VocabularyCatalog.load(from: bundle, resource: "vocabulary/catalog")
        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(catalog.packs.count, 6)
        let total = catalog.packs.reduce(0) { $0 + $1.termCount }
        XCTAssertEqual(total, 408_036, "六包詞表加總必須是 408,036 詞")
    }

    func testCleanupTokenLimit200() throws {
        let bundle = VocabularyPacks.resourceBundle
        let catalog = try VocabularyCatalog.load(from: bundle, resource: "vocabulary/catalog")
        let personal = ["Jemin": "Gemini", "ChitGPT": "ChatGPT"]
        // 把所有包 enabled，並把 terms 載入；用中文逐字稿觸發 bigram overlap
        var packs: [VocabularyCatalog.Pack] = []
        for var pack in catalog.packs {
            if let terms = VocabularyPacks.termsSource.readTermsFile(packID: pack.id) {
                pack = VocabularyCatalog.Pack(id: pack.id, name: pack.name, summary: pack.summary,
                                              sourceName: pack.sourceName, sourceURL: pack.sourceURL,
                                              licenseName: pack.licenseName, licenseURL: pack.licenseURL,
                                              attribution: pack.attribution, version: pack.version,
                                              defaultOn: pack.defaultOn, seedTerms: pack.seedTerms,
                                              termCount: pack.termCount, termsSHA256: pack.termsSHA256,
                                              terms: terms, termsFile: pack.termsFile)
            }
            packs.append(pack)
        }
        let result = VocabularySelector.termsForCleanup(
            text: "我今天在醫院做健康檢查",
            enabled: packs,
            personal: personal,
            stations: Set(TaiwanPlaces.contextualStrings)
        )
        XCTAssertLessThanOrEqual(result.count, 200, "cleanup 提示詞必須 ≤ 200")
    }

    func testEnabledPacksDefaultAllOff() {
        let enabled = VocabularyPacks.enabledCatalogPacks(enabled: [])
        // 全部 defaultOn = false → 沒人 enabled
        XCTAssertTrue(enabled.isEmpty)
    }

    func testLatinSeedTermsAreSeedsOnly() throws {
        let bundle = VocabularyPacks.resourceBundle
        let catalog = try VocabularyCatalog.load(from: bundle, resource: "vocabulary/catalog")
        // 用 enabled 集合讓六包全開（不實際觸發 lazy load）
        let allIDs = Set(VocabularyCatalog.Catalog.knownIDs)
        var packs: [VocabularyCatalog.Pack] = []
        for pack in catalog.packs where allIDs.contains(pack.id) {
            packs.append(pack)
        }
        let seeds = VocabularySelector.latinSeedTerms(enabled: packs)
        // Latin seeds 必須全部來自 seedTerms；count ≤ sum(seedTerms.count across packs)
        let maxCount = packs.reduce(0) { $0 + $1.seedTerms.count }
        XCTAssertLessThanOrEqual(seeds.count, maxCount)
        // 不會被 408k 詞污染
        XCTAssertLessThan(seeds.count, 200)
        // 每個 seed 至少含一個 ASCII 字母
        for s in seeds {
            XCTAssertTrue(s.contains(where: { $0.isASCII && $0.isLetter }),
                          "seed 必須含拉丁字母：\(s)")
        }
    }

    func testDisabledPackDoesNotMutatePersonalDictionary() throws {
        let bundle = VocabularyPacks.resourceBundle
        _ = try VocabularyCatalog.load(from: bundle, resource: "vocabulary/catalog")
        // 「全關」狀態下，cleanup 結果不該把任何 pack 詞塞進 personal dictionary
        let result = VocabularySelector.termsForCleanup(
            text: "我在醫院開會",
            enabled: [], // 全部關掉
            personal: [:],
            stations: []
        )
        XCTAssertTrue(result.isEmpty, "全關時 cleanup 不該回任何詞")
    }

    // MARK: - asr-vocab-1／v3（2026-10-22）：內建三包、提示詞排序、migration、Apple 語音退路

    /// 提示詞照 iOS cloudHints 排：個人字典 → 產品名 → 音訊 → AI → 其他內建 → catalog。舊 Mac：個人字典後讓 AI 名稱跟
    /// catalog seed 輪流排，音訊包根本不存在。
    func testContextualHintsFollowMobileOrder() throws {
        let enabled = Set(VocabularyCatalog.Catalog.knownIDs).union(BuiltInVocabulary.ids)
        let hints = VocabularyPacks.contextualHints(personal: ["bad-spelling": "CanonicalFixture"], enabled: enabled, limit: 80)
        XCTAssertEqual(Array(hints.prefix(4)), ["CanonicalFixture", "UTUVO Type", "UTUVO", "Dolby Atmos"])
        for term in ["Pro Tools", "Spatial Audio", "AIFC", "Tonmeister", "Gemini", "Claude"] { XCTAssertTrue(hints.contains(term), term) }
        XCTAssertFalse(hints.contains("Typeless"), "包內的 Typeless 不送（pn05）")
        let gemini = try XCTUnwrap(hints.firstIndex(of: "Gemini"))
        XCTAssertGreaterThan(gemini, try XCTUnwrap(hints.firstIndex(of: "AIFC")), "AI 包在音訊包之後")
        let catalogSeeds = Set(VocabularyPacks.enabledCatalogPacks(enabled: enabled).flatMap(\.seedTerms))
            .subtracting(BuiltInVocabulary.enabledTerms(enabled))
        let firstSeed = hints.firstIndex(where: catalogSeeds.contains) ?? hints.count
        XCTAssertGreaterThan(firstSeed, gemini, "catalog 種子排在內建包後面")
        XCTAssertEqual(hints.count, 80)
    }

    func testContextualHintsTraditionalAndDisabledPacks() {
        let hints = VocabularyPacks.contextualHints(personal: ["邀请码": ""], enabled: ["ai"], limit: 200, traditional: true)
        XCTAssertEqual(hints.first, "邀請碼", "台灣繁體輸出時字典裡的簡體詞先轉繁體")
        XCTAssertFalse(hints.contains("Pro Tools"), "audio 預設關，關著不送")
        XCTAssertFalse(hints.contains("淡水站"))
        XCTAssertEqual(VocabularyPacks.contextualHints(personal: ["邀请码": ""], enabled: [], limit: 200).first, "邀请码")
    }

    /// 本機整理版的修正詞：ai 關掉就沒有 AI 名稱；音訊包開著才有 Pro Tools／Spatial Audio；單字包內詞不進來。
    func testLatinFixerTermsFollowBuiltInToggles() {
        let off = VocabularyPacks.latinTermsForFixer(personal: [:], enabled: [])
        XCTAssertEqual(off, BuiltInVocabulary.productNames)
        let audio = VocabularyPacks.latinTermsForFixer(personal: [:], enabled: ["ai", "audio"])
        for term in ["Gemini", "Claude Code", "Pro Tools", "Spatial Audio"] { XCTAssertTrue(audio.contains(term), term) }
        for term in ["Typeless", "iPhone", "SDK", "Tonmeister", "AIFC"] { XCTAssertFalse(audio.contains(term), term) }
    }

    /// 整理後補套的英文專名：個人字典＋產品名全留，包內只留多字詞。
    func testLatinTermsForCleanedText() {
        let terms = VocabularyPacks.latinTermsForCleanedText(personal: ["DAMI music": "", "bad": "Canonical Fixture"],
                                                             enabled: ["ai", "tw", "audio"])
        XCTAssertEqual(Array(terms.prefix(4)).sorted(), ["Canonical Fixture", "DAMI music", "UTUVO", "UTUVO Type"])
        for term in ["Claude Code", "Pro Tools", "Spatial Audio", "Google Gemini"] { XCTAssertTrue(terms.contains(term), term) }
        for term in ["Claude", "Gemini", "iPhone", "Typeless", "AIFC", "bad"] { XCTAssertFalse(terms.contains(term), term) }
    }

    /// 整理選詞（雲端整理提示詞的詞表）：開著的內建包跟 catalog 一樣併進去；audio 關著就沒有。
    func testCleanupTermsIncludeEnabledBuiltInPacks() {
        let text = "這首要轉成 AIFC，用 Pro Tools 混 Spatial Audio"
        let on = VocabularyPacks.termsForCleanup(text: text, personal: [:], enabled: ["ai", "audio"])
        for term in ["AIFC", "Pro Tools", "Spatial Audio"] { XCTAssertTrue(on.contains(term), "\(term) in \(on)") }
        let off = VocabularyPacks.termsForCleanup(text: text, personal: [:], enabled: ["ai"])
        XCTAssertFalse(off.contains("AIFC"))
        XCTAssertFalse(off.contains("Spatial Audio"))
        XCTAssertLessThanOrEqual(on.count, 200)
    }

    func testBuiltInPseudoPacksSeedsSkipStations() {
        let stations = Set(TaiwanPlaces.contextualStrings)
        let packs = VocabularyPacks.builtInPseudoPacks(enabled: ["tw", "audio"], stations: stations)
        XCTAssertEqual(packs.map(\.id), ["__builtin_tw", "__builtin_audio"])
        XCTAssertTrue(packs[0].seedTerms.contains("西門町"))
        XCTAssertFalse(packs[0].seedTerms.contains { stations.contains($0) }, "站名不當種子")
        XCTAssertEqual(packs[1].seedTerms.count, BuiltInVocabulary.audio.seedCount)
        XCTAssertEqual(packs[1].terms, BuiltInVocabulary.audio.terms)
    }

    /// Apple 語音退路：去重、上限 100（`SFSpeechRecognitionRequest.contextualStrings` 的條數）。
    func testSpeechHintsAreDedupedAndBounded() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        AudioCaptureSession.applySpeechHints(["A", "A", ""] + (0..<150).map { "詞\($0)" }, to: request)
        XCTAssertEqual(request.contextualStrings.count, AudioCaptureSession.speechHintLimit)
        XCTAssertEqual(AudioCaptureSession.speechHintLimit, 100)
        XCTAssertEqual(Array(request.contextualStrings.prefix(2)), ["A", "詞0"])
        AudioCaptureSession.applySpeechHints([], to: request)
        XCTAssertEqual(request.contextualStrings, [])
    }
}

/// migration 跟 AppModel 要 MainActor（AppPreferences 是 MainActor）。
@MainActor
final class VocabularyPacksPreferencesTests: XCTestCase {
    /// 舊版 Mac 只存 catalog id（AI 名稱寫死一直開）。升級第一次要把 ai、tw 補進去；之後使用者關掉就不再補。
    func testOneTimeMigrationKeepsAiAndTwOnForExistingUsers() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        context.userDefaults.set(["music", "law"], forKey: "utuvo.type.vocabularyPacks.enabled")
        let first = AppPreferences(isolation: context)
        XCTAssertEqual(first.enabledVocabularyPackIDs, ["music", "law", "ai", "tw"])
        XCTAssertTrue(context.userDefaults.bool(forKey: "utuvo.type.vocabularyPacks.builtInMigrated"))
        XCTAssertEqual(Set(context.userDefaults.stringArray(forKey: "utuvo.type.vocabularyPacks.enabled") ?? []),
                       ["music", "law", "ai", "tw"], "migration 結果要寫回")
        first.enabledVocabularyPackIDs.remove("ai")
        first.enabledVocabularyPackIDs.insert("audio")
        let second = AppPreferences(isolation: context)
        XCTAssertEqual(second.enabledVocabularyPackIDs, ["music", "law", "tw", "audio"], "使用者關掉的 ai 不能被補回來")
    }

    /// 所有引擎從同一份排好的清單取前 N 個：Qwen／Groq 80 是 Apple 100 的前 80 個。
    func testModelHintsAreOnePrefixOrderedList() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.enabledVocabularyPackIDs = Set(VocabularyCatalog.Catalog.knownIDs).union(BuiltInVocabulary.ids)
        preferences.dictionaryJSON = #"{"DAMI music":""}"#
        let model = AppModel(preferences: preferences)
        let apple = model.asrHints(limit: AudioCaptureSession.speechHintLimit)
        XCTAssertEqual(apple.count, 100)
        XCTAssertEqual(Array(apple.prefix(80)), model.asrHints(limit: 80))
        XCTAssertEqual(Array(apple.prefix(50)), model.asrHints(limit: 50))
        XCTAssertEqual(apple.first, "DAMI music")
        XCTAssertTrue(apple.contains("Pro Tools"))
    }

    /// verifier（fx-hints）：預設 Mac（zh-TW、台灣繁體）＋個人字典，以前送出 周傑倫／奇巖站／乾擾。
    /// 已經是繁體或兩邊通用的詞照打的送；簡體寫的才轉（OpenCC 按詞：周杰伦→周杰倫，ICU 會給周傑倫）。
    func testDefaultMacHintsKeepTraditionalDictionaryEntries() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        XCTAssertEqual(preferences.transcriptionLanguage, .traditionalChinese)
        XCTAssertEqual(preferences.outputScript, .traditional)
        preferences.dictionaryJSON = #"{"周杰倫":"","干擾":"","奇岩站":"","邀请码":""}"#
        let model = AppModel(preferences: preferences)
        XCTAssertEqual(Array(model.asrHints(limit: 100).prefix(6)), ["周杰倫", "奇岩站", "干擾", "邀請碼", "UTUVO Type", "UTUVO"])

        preferences.dictionaryJSON = #"{"周杰伦":"","干扰":""}"#
        XCTAssertEqual(Array(model.asrHints(limit: 100).prefix(2)), ["周杰倫", "干擾"], "簡體寫的按詞轉台灣繁體")

        preferences.dictionaryJSON = "{}"
        preferences.enabledVocabularyPackIDs = ["tw"]
        let tw = model.asrHints(limit: 1_000)
        for station in ["奇岩站", "頭前庄站"] { XCTAssertTrue(tw.contains(station), station) }
        for wrong in ["奇巖站", "頭前莊站"] { XCTAssertFalse(tw.contains(wrong), wrong) }
    }

    /// verifier（fx-hints）：zh-TW＋簡體輸出時，提示詞尾巴是繁體站名、音訊包帶 母帶／分軌／錄音室。
    func testSimplifiedOutputHintsCarryNoTraditionalOnlyCharacters() throws {
        let context = try IsolatedContext.make(); defer { context.tearDown() }
        let preferences = AppPreferences(isolation: context)
        preferences.outputScript = .simplified
        preferences.enabledVocabularyPackIDs = ["ai", "tw", "audio"]
        preferences.dictionaryJSON = #"{"邀请码":""}"#
        let model = AppModel(preferences: preferences)
        let apple = model.asrHints(limit: AudioCaptureSession.speechHintLimit)
        XCTAssertEqual(apple.first, "邀请码", "簡體詞照打的送")
        XCTAssertEqual(apple.filter(HanScript.hasTraditionalOnly), [], "簡體輸出不送繁體專用字")
        let cloud = model.asrHints(limit: 80)
        for term in ["混音", "母带", "分轨", "录音室"] { XCTAssertTrue(cloud.contains(term), term) }
        XCTAssertEqual(Array(apple.prefix(80)), cloud)
    }
}
