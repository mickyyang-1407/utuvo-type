import XCTest
@testable import UTUVOTypeCore

/// asr-vocab-1（2026-10-22）：內建三包（ai／tw／audio）搬進 core 當 Mac 的唯一 Swift 正本，
/// 辨識提示詞照 iOS `SpeechEngine.cloudHints` 排：個人字典 → 產品名 → 音訊 → AI → 其他內建 → catalog。
/// Android 的詞表在 app 模組（`VocabularyPacks.kt`），這裡讀檔逐詞比對；任何一邊改了，這裡就紅。
final class BuiltInVocabularyTests: XCTestCase {
    private let catalogIDs = ["computing", "medicine", "finance", "law", "engineering", "music"]

    // MARK: - 詞表與預設

    func testDefaultsMatchMobile() {
        XCTAssertEqual(BuiltInVocabulary.all.map(\.id), ["ai", "tw", "audio"])
        XCTAssertEqual(BuiltInVocabulary.defaultOnIDs, ["ai", "tw"], "預設 ai、tw 開，audio 關（同 iOS／Android）")
        XCTAssertTrue(BuiltInVocabulary.ids.isDisjoint(with: catalogIDs), "跟 catalog 六包存在同一份集合，id 不能撞")
    }

    func testAudioPackHasBenchFailureTerms() {
        let audio = BuiltInVocabulary.audio.terms
        for term in ["Spatial Audio", "AIFF", "AIFC", "Tonmeister", "Pro Tools", "stems", "母帶"] {
            XCTAssertTrue(audio.contains(term), term)
        }
        XCTAssertEqual(Set(audio).count, audio.count, "包內不重複")
    }

    func testTaiwanPackKeepsStationsAndPlaces() {
        XCTAssertEqual(BuiltInVocabulary.stationNames.first, "淡水站")
        XCTAssertEqual(BuiltInVocabulary.stationNames.count, Set(BuiltInVocabulary.taipeiMRT).count, "站名去重")
        XCTAssertTrue(BuiltInVocabulary.tw.terms.contains("圓山站"))
        XCTAssertTrue(BuiltInVocabulary.tw.terms.contains("西門町"))
        XCTAssertEqual(BuiltInVocabulary.tw.seedCount, .max)
    }

    // MARK: - 提示詞排序（cloudHints）

    private let medicineSeeds = (0..<40).map { "醫學種子\($0)" }
    private let lawSeeds = (0..<31).map { "法律種子\($0)" }

    func testHintOrderIsPersonalProductAudioAiOtherThenCatalog() throws {
        let hints = BuiltInVocabulary.asrHints(personal: ["DAMI music", "楊敏奇"], enabled: ["ai", "tw", "audio", "medicine"],
                                               catalogSeeds: medicineSeeds, traditional: false, limit: 1_000)
        XCTAssertEqual(Array(hints.prefix(4)), ["DAMI music", "楊敏奇", "UTUVO Type", "UTUVO"])
        let audioStart = try XCTUnwrap(hints.firstIndex(of: "Dolby Atmos"))
        XCTAssertEqual(audioStart, 4, "音訊包緊接在產品名後面")
        let aiStart = try XCTUnwrap(hints.firstIndex(of: "Gemini"))
        XCTAssertGreaterThan(aiStart, try XCTUnwrap(hints.firstIndex(of: "AIFC")), "AI 包在音訊包整包之後")
        let station = try XCTUnwrap(hints.firstIndex(of: "淡水站"))
        XCTAssertGreaterThan(station, try XCTUnwrap(hints.firstIndex(of: "Vibe Coding")), "其他內建包在 AI 包之後")
        XCTAssertGreaterThan(try XCTUnwrap(hints.firstIndex(of: "醫學種子0")), try XCTUnwrap(hints.firstIndex(of: "全家")),
                             "catalog 種子最後")
    }

    /// 舊 Mac 排法：個人字典之後就讓 catalog 種子跟 AI 名稱輪流排，六包全開時 80 個名額被醫療／法律種子吃掉。
    func testCatalogSeedsCannotCrowdOutAudioTermsInTheFirst80() {
        let personal = (0..<29).map { "個人詞\($0)" }
        let seeds = medicineSeeds + lawSeeds + (0..<40).map { "工程種子\($0)" }
        let hints = BuiltInVocabulary.asrHints(personal: personal, enabled: Set(["ai", "tw", "audio"] + catalogIDs),
                                               catalogSeeds: seeds, traditional: false, limit: 80)
        XCTAssertEqual(hints.count, 80)
        for term in ["Pro Tools", "stems", "母帶", "Tonmeister", "Spatial Audio", "AIFC"] {
            XCTAssertTrue(hints.contains(term), term)
        }
        XCTAssertFalse(hints.contains { $0.contains("種子") }, "名額不夠時 catalog 種子排不進來")
    }

    func testDisabledPacksStayOut() {
        let hints = BuiltInVocabulary.asrHints(personal: [], enabled: ["ai"], catalogSeeds: [], traditional: false, limit: 1_000)
        XCTAssertFalse(hints.contains("Pro Tools"), "audio 關著不出聲")
        XCTAssertFalse(hints.contains("淡水站"), "tw 關著不出聲")
        XCTAssertTrue(hints.contains("Gemini"))
        let none = BuiltInVocabulary.asrHints(personal: [], enabled: [], catalogSeeds: [], traditional: false, limit: 1_000)
        XCTAssertEqual(none, BuiltInVocabulary.productNames, "全關只剩產品名")
    }

    /// verifier：使用者說「Type」，模型會被「Typeless」拉過去（pn05）。包內的 Typeless 不送；使用者自己加的照送。
    func testTypelessIsNotSentAsAPackHintButPersonalEntryIs() {
        let hints = BuiltInVocabulary.asrHints(personal: [], enabled: ["ai"], catalogSeeds: [], traditional: false, limit: 1_000)
        XCTAssertFalse(hints.contains("Typeless"))
        XCTAssertTrue(hints.contains("Chatterfly"), "同一包其他詞照送")
        let personal = BuiltInVocabulary.asrHints(personal: ["Typeless"], enabled: ["ai"], catalogSeeds: [], traditional: false, limit: 1_000)
        XCTAssertEqual(personal.first, "Typeless")
    }

    func testTraditionalConvertsSimplifiedEntriesAndDeduplicates() {
        let zhTW = BuiltInVocabulary.asrHints(personal: ["邀请码", "邀請碼", "楊敏奇"], enabled: [], catalogSeeds: [],
                                              traditional: true, limit: 10)
        XCTAssertEqual(zhTW, ["邀請碼", "楊敏奇", "UTUVO Type", "UTUVO"], "簡體轉繁體後跟原本的繁體詞合併")
        let asIs = BuiltInVocabulary.asrHints(personal: ["邀请码"], enabled: [], catalogSeeds: [], traditional: false, limit: 10)
        XCTAssertEqual(asIs.first, "邀请码", "簡體輸出時不轉")
        XCTAssertTrue(BuiltInVocabulary.usesTraditionalHints(language: "zh-TW"))
        XCTAssertFalse(BuiltInVocabulary.usesTraditionalHints(language: "zh-CN"))
        XCTAssertFalse(BuiltInVocabulary.usesTraditionalHints(language: "zh-Hans"))
        XCTAssertFalse(BuiltInVocabulary.usesTraditionalHints(language: "en-US"))
    }

    // MARK: - 提示詞字形（fx-hints）：已經是繁體的詞不能被 ICU 逐字轉壞

    /// verifier：預設 Mac（zh-TW、台灣繁體）＋個人字典 周杰倫／干擾／奇岩站／邀请码，以前送出 周傑倫／奇巖站／乾擾。
    /// 繁體、兩邊通用的詞照使用者打的送；只有簡體寫的才轉。
    func testTraditionalHintsKeepTraditionalPersonalEntries() {
        let personal = ["周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "邀请码"]
        let hints = BuiltInVocabulary.asrHints(personal: personal, enabled: [], catalogSeeds: [], script: .traditional, limit: 100)
        XCTAssertEqual(hints, ["周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "邀請碼",
                               "UTUVO Type", "UTUVO"])
        XCTAssertEqual(BuiltInVocabulary.asrHints(personal: ["奇岩站", "干擾"], enabled: [], catalogSeeds: [],
                                                  traditional: true, limit: 2), ["奇岩站", "干擾"], "舊介面同一條規則")
    }

    /// 只有簡體寫的個人詞會交給轉換器（Mac／Android 傳 OpenCC 按詞轉）；繁體、兩邊通用、英文都不經過它。
    func testOnlySimplifiedPersonalEntriesReachTheConverter() {
        var converted: [String] = []
        let hints = BuiltInVocabulary.asrHints(
            personal: ["周杰倫", "干擾", "奇岩站", "于美人", "后里", "邀请码", "周杰伦", "Atmos", "頭前庄站"],
            packTerms: ["淡水站", "奇岩站", "頭前庄站", "混音", "Typeless"], script: .traditional, limit: 100,
            toTraditional: { converted.append($0); return "〔\($0)〕" })
        XCTAssertEqual(converted, ["邀请码", "周杰伦"])
        XCTAssertEqual(hints, ["周杰倫", "干擾", "奇岩站", "于美人", "后里", "〔邀请码〕", "〔周杰伦〕", "Atmos", "頭前庄站",
                               "UTUVO Type", "UTUVO", "淡水站", "混音"], "內建包不轉、照樣去重、Typeless 不送")
    }

    /// verifier：tw 開著時提示詞裡是 奇巖站、頭前莊站，真的站名 奇岩站、頭前庄站 不見了。內建包一個字都不能動。
    func testTraditionalHintsSendBuiltInPackTermsVerbatim() {
        let hints = BuiltInVocabulary.asrHints(personal: [], enabled: BuiltInVocabulary.ids, catalogSeeds: [],
                                               script: .traditional, limit: 1_000)
        for pack in BuiltInVocabulary.all {
            for term in pack.terms where !BuiltInVocabulary.asrHintExclusions.contains(term) {
                XCTAssertTrue(hints.contains(term), "\(pack.id)：\(term)")
            }
        }
        XCTAssertFalse(hints.contains("奇巖站"))
        XCTAssertFalse(hints.contains("頭前莊站"))
    }

    /// verifier：zh-TW＋簡體輸出時，Apple 100 個提示詞的尾巴是 芝山站／士林站／劍潭站…，音訊包帶 母帶、分軌、錄音室。
    func testSimplifiedHintsCarryNoTraditionalOnlyCharacters() {
        let hints = BuiltInVocabulary.asrHints(personal: ["邀请码", "楊敏奇", "周杰伦"], enabled: BuiltInVocabulary.ids,
                                               catalogSeeds: ["臨床試驗"], script: .simplified, limit: 1_000)
        XCTAssertEqual(Array(hints.prefix(5)), ["邀请码", "杨敏奇", "周杰伦", "UTUVO Type", "UTUVO"], "簡體詞照打的送")
        for term in ["双连站", "剑潭站", "母带", "分轨", "录音室", "混音", "奇岩站", "临床试验"] {
            XCTAssertTrue(hints.contains(term), term)
        }
        XCTAssertEqual(hints.filter(HanScript.hasTraditionalOnly), [], "簡體輸出不送繁體專用字")
    }

    /// 簡體輸出：有繁體專用字的詞（個人＋內建包）才交給繁轉簡；簡體、兩邊通用、英文都原樣（Android core 同一個案例）。
    func testSimplifiedScriptOnlyConvertsTermsWithTraditionalOnlyCharacters() {
        var converted: [String] = []
        let hints = BuiltInVocabulary.asrHints(
            personal: ["邀请码", "楊敏奇", "周杰伦"], packTerms: ["雙連站", "奇岩站", "混音", "母帶", "Pro Tools"],
            script: .simplified, limit: 100, toTraditional: { XCTFail("不該轉繁體：\($0)"); return $0 },
            toSimplified: { converted.append($0); return "〔\($0)〕" })
        XCTAssertEqual(converted, ["楊敏奇", "雙連站", "母帶"])
        XCTAssertEqual(hints, ["邀请码", "〔楊敏奇〕", "周杰伦", "UTUVO Type", "UTUVO", "〔雙連站〕", "奇岩站", "混音", "〔母帶〕",
                               "Pro Tools"])
    }

    func testHintScriptFollowsLanguageAndOutput() {
        XCTAssertEqual(BuiltInVocabulary.hintScript(language: "zh-TW", simplifiedOutput: false), .traditional)
        XCTAssertEqual(BuiltInVocabulary.hintScript(language: "zh-TW", simplifiedOutput: true), .simplified)
        XCTAssertEqual(BuiltInVocabulary.hintScript(language: "zh-CN", simplifiedOutput: false), .simplified)
        XCTAssertEqual(BuiltInVocabulary.hintScript(language: "en-US", simplifiedOutput: true), .asIs)
        XCTAssertEqual(BuiltInVocabulary.hintScript(language: "auto", simplifiedOutput: false), .asIs)
    }

    func testHanScriptTellsSimplifiedFromTraditionalAndShared() {
        for term in ["邀请码", "周杰伦", "头发", "后来", "范晓萱", "为什么", "干扰", "体育"] {
            XCTAssertTrue(HanScript.isSimplified(term), term)
        }
        // 繁體、兩邊通用（杰 干 岩 庄 范 于 后 台 雇 疱）、繁簡混寫、英文：都不算簡體
        for term in ["周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "台北", "雇主", "杰克",
                     "沉默", "疱疹", "邀請码", "Atmos", ""] {
            XCTAssertFalse(HanScript.isSimplified(term), term)
        }
        XCTAssertTrue(HanScript.hasTraditionalOnly("雙連站"))
        XCTAssertFalse(HanScript.hasTraditionalOnly("奇岩站"))
    }

    /// 字表 Mac／Android 同一份（scripts/build-han-script.py 一次寫兩邊）。
    func testHanScriptDataMatchesAndroidCore() throws {
        let kotlin = try String(contentsOfFile: TestSupport.repoRoot()
                                + "/android/core/src/main/kotlin/com/utuvo/type/core/HanScriptData.kt", encoding: .utf8)
        func block(_ name: String) throws -> String {
            let start = try XCTUnwrap(kotlin.range(of: "const val \(name) = \"\"\""), name)
            let end = try XCTUnwrap(kotlin.range(of: "\"\"\"", range: start.upperBound..<kotlin.endIndex))
            return String(kotlin[start.upperBound..<end.lowerBound].unicodeScalars.filter { !$0.properties.isWhitespace })
        }
        let swiftSimplified = String(HanScriptData.simplifiedOnly.unicodeScalars.filter { !$0.properties.isWhitespace })
        let swiftTraditional = String(HanScriptData.traditionalOnly.unicodeScalars.filter { !$0.properties.isWhitespace })
        XCTAssertEqual(try block("SIMPLIFIED_ONLY"), swiftSimplified)
        XCTAssertEqual(try block("TRADITIONAL_ONLY"), swiftTraditional)
        XCTAssertGreaterThan(HanScript.simplifiedOnly.count, 2_000)
        XCTAssertGreaterThan(HanScript.traditionalOnly.count, 3_000)
    }

    /// Android 雲端提示詞（core `AsrHints`）也不送包內的 Typeless。
    func testAndroidHintExclusionsMatchCore() throws {
        let kotlin = try String(contentsOfFile: TestSupport.repoRoot()
                                + "/android/core/src/main/kotlin/com/utuvo/type/core/HanScript.kt", encoding: .utf8)
        let start = try XCTUnwrap(kotlin.range(of: "val EXCLUSIONS: Set<String> = setOf("))
        let end = try XCTUnwrap(kotlin.range(of: ")", range: start.upperBound..<kotlin.endIndex))
        XCTAssertEqual(Set(quoted(kotlin[start.upperBound..<end.lowerBound])), BuiltInVocabulary.asrHintExclusions)
    }

    func testLimitIsRespectedAndEmptyTermsDropped() {
        let hints = BuiltInVocabulary.asrHints(personal: ["", "A1"], enabled: ["ai", "audio", "tw"], catalogSeeds: [],
                                               traditional: false, limit: 5)
        XCTAssertEqual(hints, ["A1", "UTUVO Type", "UTUVO", "Dolby Atmos", "Atmos"])
        XCTAssertEqual(BuiltInVocabulary.asrHints(personal: ["A1"], enabled: ["ai"], catalogSeeds: [], traditional: false, limit: 0), [])
    }

    func testEnabledTermsFollowPackOrderWithoutDuplicates() {
        let terms = BuiltInVocabulary.enabledTerms(["audio", "ai"])
        XCTAssertEqual(terms.first, "Gemini", "照 all 的順序（ai 先）")
        XCTAssertTrue(terms.contains("Pro Tools"))
        XCTAssertFalse(terms.contains("西門町"))
        XCTAssertEqual(Set(terms).count, terms.count)
    }

    // MARK: - 英文專名修正搭配新詞（asr-vocab-1 bench 失誤）

    /// 本機整理版的英文專名修正：產品名＋`fixerTerms`（ai 開著時那 12 個 AI 名稱＋已開各包的多字詞）。
    func testAudioTermsFixBenchMishearingsOnlyWhenEnabled() {
        let on = BuiltInVocabulary.productNames + BuiltInVocabulary.fixerTerms(["ai", "audio"])
        XCTAssertEqual(LatinNameFixer.fix("這首要做 Special Audio 版本", terms: on), "這首要做 Spatial Audio 版本")
        XCTAssertEqual(LatinNameFixer.fix("更新 Protus", terms: on), "更新 Pro Tools")
        // 不該改：AIFC 是自己的格式，不能被收成 AIFF；正確的寫法一個字都不動。
        XCTAssertEqual(LatinNameFixer.fix("轉成 AIFC 再轉 AIFF", terms: on), "轉成 AIFC 再轉 AIFF")
        XCTAssertEqual(LatinNameFixer.fix("I like these types of mixes", terms: on), "I like these types of mixes")
        // Tonmeister 是單字詞，不進修正器（ToneMaster 靠辨識提示詞帶回來，見 testCatalogSeedsCannotCrowdOutAudioTermsInTheFirst80）。
        XCTAssertFalse(on.contains("Tonmeister"))
        let off = BuiltInVocabulary.productNames + BuiltInVocabulary.fixerTerms(["ai"])
        XCTAssertEqual(LatinNameFixer.fix("這首要做 Special Audio 版本", terms: off), "這首要做 Special Audio 版本")
    }

    /// 修正器只吃舊 Mac 那 12 個 AI 名稱＋多字詞：整包 ai 的單字詞放進去，前兩萬個常用英文字有 296 個會被改掉。
    func testFixerTermsKeepTheOldMacNamesAndAddOnlyPhrases() {
        XCTAssertEqual(BuiltInVocabulary.fixerTerms([]), [])
        let ai = BuiltInVocabulary.fixerTerms(["ai"])
        XCTAssertEqual(Array(ai.prefix(BuiltInVocabulary.aiNameFixerTerms.count)), BuiltInVocabulary.aiNameFixerTerms)
        XCTAssertTrue(ai.dropFirst(BuiltInVocabulary.aiNameFixerTerms.count).allSatisfy(BuiltInVocabulary.isLatinPhrase))
        for single in ["Typeless", "iPhone", "Zhipu", "SDK", "commit", "Meta"] {
            XCTAssertFalse(ai.contains(single), single)
        }
        XCTAssertTrue(ai.contains("Claude Code"))
        XCTAssertEqual(BuiltInVocabulary.fixerTerms(["audio"]).first, "Dolby Atmos", "ai 關著就沒有 AI 名稱")
        let all = BuiltInVocabulary.productNames + BuiltInVocabulary.fixerTerms(BuiltInVocabulary.ids)
        for sentence in ["my phone is in the shop", "these types of stock", "commits are pushed", "I like these types of mixes"] {
            XCTAssertEqual(LatinNameFixer.fix(sentence, terms: all), sentence)
        }
    }

    // MARK: - 跟 Android 詞表逐詞比對

    private func androidSource() throws -> String {
        try String(contentsOfFile: TestSupport.repoRoot() + "/android/app/src/main/kotlin/com/utuvo/type/VocabularyPacks.kt",
                   encoding: .utf8)
    }

    /// 去掉 `//` 註解後抓雙引號字串。
    private func quoted(_ text: Substring) -> [String] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            guard let range = line.range(of: "//") else { return line }
            return line[..<range.lowerBound]
        }.joined(separator: "\n")
        var out: [String] = []
        var current: String?
        for c in code {
            if c == "\"" {
                if let value = current { out.append(value); current = nil } else { current = "" }
            } else if current != nil {
                current!.append(c)
            }
        }
        return out
    }

    /// `Pack(` 呼叫的頂層參數（略過字串、`//` 註解與括號裡的逗號）。
    private func packArguments(_ call: Substring) -> [String]? {
        guard let open = call.firstIndex(of: "(") else { return nil }
        var depth = 0
        var inString = false
        var args: [String] = []
        var current = ""
        var i = call.index(after: open)
        while i < call.endIndex {
            let c = call[i]
            let next = call.index(after: i)
            if inString {
                current.append(c)
                if c == "\\", next < call.endIndex { current.append(call[next]); i = call.index(after: next); continue }
                if c == "\"" { inString = false }
            } else if c == "/", next < call.endIndex, call[next] == "/" {
                i = call[i...].firstIndex(of: "\n") ?? call.endIndex
                continue
            } else if c == "\"" {
                inString = true
                current.append(c)
            } else if "([{".contains(c) {
                depth += 1
                current.append(c)
            } else if ")]}".contains(c) {
                if depth == 0 {
                    args.append(current)
                    return args.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                depth -= 1
                current.append(c)
            } else if c == ",", depth == 0 {
                args.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = next
        }
        return nil
    }

    /// `Pack(id, nameRes, summary, terms, defaultOn, seedCount)` 的 defaultOn：具名（`defaultOn = true`）優先，否則第 5 個位置參數。
    /// 以前只認 `),true`，寫成具名參數的 `defaultOn = true` 會被當成 false（hollow parity，fx-hints）。
    private func packDefaultOn(_ call: Substring) -> Bool? {
        guard let args = packArguments(call) else { return nil }
        var positional: [String] = []
        var named: [String: String] = [:]
        for arg in args {
            if let eq = arg.firstIndex(of: "="), arg[arg.index(after: eq)...].first != "=",
               case let name = arg[..<eq].trimmingCharacters(in: .whitespaces),
               !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                named[name] = arg[arg.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                positional.append(arg)
            }
        }
        switch named["defaultOn"] ?? (positional.count > 4 ? positional[4] : nil) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func androidPacks() throws -> [String: (terms: [String], defaultOn: Bool)] {
        try androidPacks(source: androidSource())
    }

    private func androidPacks(source: String) throws -> [String: (terms: [String], defaultOn: Bool)] {
        let mrtStart = try XCTUnwrap(source.range(of: "val taipeiMRT = listOf("), "Android taipeiMRT 不見了")
        let mrtEnd = try XCTUnwrap(source.range(of: ")", range: mrtStart.upperBound..<source.endIndex))
        var seen = Set<String>()
        let stations = quoted(source[mrtStart.upperBound..<mrtEnd.lowerBound]).filter { seen.insert($0).inserted }.map { $0 + "站" }
        let allStart = try XCTUnwrap(source.range(of: "val all = listOf("), "Android 內建包 all 不見了")
        let allEnd = try XCTUnwrap(source.range(of: "\n    )\n", range: allStart.upperBound..<source.endIndex))
        let body = source[allStart.upperBound..<allEnd.lowerBound]
        var packs: [String: (terms: [String], defaultOn: Bool)] = [:]
        let starts = body.ranges(of: "Pack(\"")
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1].lowerBound : body.endIndex
            let chunk = body[start.lowerBound..<end]
            var strings = quoted(chunk)
            let id = strings.removeFirst()
            strings.removeFirst()   // summary
            var terms = strings
            if id == "tw" {
                XCTAssertTrue(chunk.contains("taipeiMRT.distinct().map { it + \"站\" }"), "tw 包的站名寫法變了，比對要跟著改")
                terms.removeAll { $0 == "站" }
                terms = stations + terms
            }
            let defaultOn = try XCTUnwrap(packDefaultOn(chunk), "\(id) 的 defaultOn 讀不出來")
            packs[id] = (terms, defaultOn)
        }
        return packs
    }

    func testAndroidPacksMatchCoreTermForTerm() throws {
        let android = try androidPacks()
        XCTAssertEqual(Set(android.keys), BuiltInVocabulary.ids)
        for pack in BuiltInVocabulary.all {
            let other = try XCTUnwrap(android[pack.id], pack.id)
            XCTAssertEqual(other.terms, pack.terms, "\(pack.id) 詞表跟 Android 不同")
            XCTAssertEqual(other.defaultOn, pack.defaultOn, "\(pack.id) 預設開關跟 Android 不同")
        }
    }

    /// verifier 的突變：把 audio 的預設改成具名參數 `defaultOn = true`，比對要讀成 true（以前讀成 false，照樣綠燈）。
    func testAndroidPackParserReadsNamedAndPositionalDefaults() throws {
        let source = try androidSource()
        let audioEnd = "\"Spatial Audio\", \"AIFF\", \"AIFC\"), false),"
        XCTAssertEqual(source.components(separatedBy: audioEnd).count, 2, "audio 包結尾寫法變了，突變要跟著改")
        let named = try androidPacks(source: source.replacingOccurrences(
            of: audioEnd, with: "\"Spatial Audio\", \"AIFF\", \"AIFC\"), defaultOn = true),"))
        XCTAssertEqual(named["audio"]?.defaultOn, true, "具名的 defaultOn = true")
        XCTAssertEqual(named["audio"]?.terms, BuiltInVocabulary.audio.terms)
        let flipped = try androidPacks(source: source.replacingOccurrences(
            of: audioEnd, with: "\"Spatial Audio\", \"AIFF\", \"AIFC\"), true),"))
        XCTAssertEqual(flipped["audio"]?.defaultOn, true, "位置參數翻成 true")
        let original = try androidPacks(source: source)
        XCTAssertEqual(original["audio"]?.defaultOn, false)
        XCTAssertEqual(original["tw"]?.defaultOn, true, "tw 後面還有具名的 seedCount")
        XCTAssertEqual(original["ai"]?.defaultOn, true)
    }

    /// 整理後補套英文專名時 Android 也要用同一組產品名（asr-vocab-2）。
    func testAndroidProductNamesMatchCore() throws {
        let source = try androidSource()
        let start = try XCTUnwrap(source.range(of: "val productNames = listOf("), "Android productNames 不見了")
        let end = try XCTUnwrap(source.range(of: ")", range: start.upperBound..<source.endIndex))
        XCTAssertEqual(quoted(source[start.upperBound..<end.lowerBound]), BuiltInVocabulary.productNames)
    }

    func testAndroidStationListMatchesCore() throws {
        let source = try androidSource()
        let start = try XCTUnwrap(source.range(of: "val taipeiMRT = listOf("))
        let end = try XCTUnwrap(source.range(of: ")", range: start.upperBound..<source.endIndex))
        XCTAssertEqual(quoted(source[start.upperBound..<end.lowerBound]), BuiltInVocabulary.taipeiMRT)
    }
}
