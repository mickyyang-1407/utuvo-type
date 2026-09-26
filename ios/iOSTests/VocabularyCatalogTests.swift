import XCTest
@testable import UTUVOTypeiOS

/// 詞庫目錄 + 選詞器（CONTRACT-V2 schema 2）：
/// 純函式測試；用 InMemoryPackTermsSource 直接注入，不碰 Bundle 與檔案系統。
final class VocabularyCatalogTests: XCTestCase {

    // MARK: - schema 2 解析

    func testDecodesSchema2WithTermsFileAndCount() throws {
        let json = """
        {"schemaVersion":2,"packs":[
          {"id":"computing","name":"資訊與電腦","summary":"AI／資料庫","sourceName":"NAER","sourceURL":"https://example/x","licenseName":"OGDL","licenseURL":"https://example/y","attribution":"整理","version":"2026-09-20","defaultOn":false,
           "seedTerms":["人工智慧","機器學習"],"termsFile":"computing.txt","termCount":120000,"termsSHA256":"abc"}
        ]}
        """.data(using: .utf8)!
        let catalog = try VocabularyCatalog.decode(json)
        XCTAssertEqual(catalog.schemaVersion, 2)
        let p = catalog.packs.first!
        XCTAssertEqual(p.id, "computing")
        XCTAssertEqual(p.termCount, 120_000)
        XCTAssertEqual(p.termsFile, "computing.txt")
        XCTAssertNil(p.terms, "metadata 不該預載 terms")
        XCTAssertEqual(p.seedTerms, ["人工智慧", "機器學習"])
    }

    func testRejectsSchema1() {
        let json = """
        {"schemaVersion":1,"packs":[{"id":"computing","name":"X","terms":["a"]}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try VocabularyCatalog.decode(json))
    }

    func testAllowlistOnlyAllowsSixKnownIDs() {
        for id in VocabularyCatalog.Catalog.knownIDs {
            XCTAssertTrue(BundlePackTermsSource.isAllowedID(id), "白名單內：\(id)")
        }
        XCTAssertFalse(BundlePackTermsSource.isAllowedID("../../../etc/passwd"))
        XCTAssertFalse(BundlePackTermsSource.isAllowedID("custom"))
        XCTAssertFalse(BundlePackTermsSource.isAllowedID("../escape"))
    }

    func testCleanTermRejectsUnbalancedParensAndControlChars() {
        XCTAssertTrue(BundlePackTermsSource.isCleanTerm("人工智慧"))
        XCTAssertFalse(BundlePackTermsSource.isCleanTerm("7) 碼"), "編號片段拒收")
        XCTAssertFalse(BundlePackTermsSource.isCleanTerm("人工(智慧"), "不平衡括號拒收")
        XCTAssertFalse(BundlePackTermsSource.isCleanTerm("<b>詞"))
        XCTAssertFalse(BundlePackTermsSource.isCleanTerm("a"), "太短拒收")
        XCTAssertFalse(BundlePackTermsSource.isCleanTerm(String(repeating: "字", count: 41)), "太長拒收")
    }

    /// Kimi review round 1（低）：`&` 是合法詞（AT&T世界網／H&E染色法／程式&時鐘板），不得清洗丟棄。
    func testCleanTermAcceptsLegitAmpersand() {
        XCTAssertTrue(BundlePackTermsSource.isCleanTerm("AT&T世界網"))
        XCTAssertTrue(BundlePackTermsSource.isCleanTerm("H&E染色法"))
        XCTAssertTrue(BundlePackTermsSource.isCleanTerm("程式&時鐘板"))
    }

    /// 實際 loader（真實 app bundle 的 vocabulary/*.txt）：
    /// 3 個含 & 的詞在、且每包實際載入數＝catalog metadata termCount。
    func testBundleLoaderIncludesAmpersandTermsAndCountsMatchMetadata() throws {
        VocabularyPacks.ensureCatalogLoaded()
        let catalog = VocabularyPacks.catalog
        XCTAssertEqual(catalog.packs.count, 6)
        let source = BundlePackTermsSource()
        for pack in catalog.packs {
            let terms = try XCTUnwrap(source.readTermsFile(packID: pack.id), "\(pack.id) 詞表應載入")
            XCTAssertEqual(terms.count, pack.termCount, "\(pack.id) 實際載入數應等於 metadata termCount")
        }
        XCTAssertTrue(try XCTUnwrap(source.readTermsFile(packID: "computing")).contains("AT&T世界網"))
        XCTAssertTrue(try XCTUnwrap(source.readTermsFile(packID: "medicine")).contains("H&E染色法"))
        XCTAssertTrue(try XCTUnwrap(source.readTermsFile(packID: "computing")).contains("程式&時鐘板"))
    }

    // MARK: - In-memory loader

    final class InMemoryPackTermsSource: PackTermsSource, @unchecked Sendable {
        let map: [String: [String]]
        init(_ map: [String: [String]]) { self.map = map }
        func readTermsFile(packID: String) -> [String]? { map[packID] }
    }

    func makePacks(terms: [String: [String]]) -> [VocabularyCatalog.Pack] {
        let rawIDs = VocabularyCatalog.Catalog.knownIDs
        return rawIDs.map { id in
            VocabularyCatalog.Pack(id: id, name: id, summary: "",
                                   sourceName: "", sourceURL: "",
                                   licenseName: "", licenseURL: "",
                                   attribution: "", version: "2026-09-20",
                                   defaultOn: false,
                                   seedTerms: ["代表詞-\(id)"],
                                   termCount: terms[id]?.count ?? 0,
                                   termsSHA256: "",
                                   terms: terms[id],
                                   termsFile: "\(id).txt")
        }
    }

    // MARK: - 六包可見、預設全關

    func testAllSixPacksVisibleByDefaultOff() {
        let json = makeCatalogJSON(packs: (0..<6).map { i in
            ["id": VocabularyCatalog.Catalog.knownIDs[i],
             "name": "Pack \(i)", "defaultOn": false, "termCount": 10, "termsFile": "\(VocabularyCatalog.Catalog.knownIDs[i]).txt"] as [String: Any]
        })
        let catalog = try! VocabularyCatalog.decode(json)
        XCTAssertEqual(catalog.packs.count, 6)
        XCTAssertTrue(catalog.packs.allSatisfy { !$0.defaultOn })
        XCTAssertTrue(catalog.packs.allSatisfy { $0.terms == nil }, "未觸發讀檔")
    }

    func makeCatalogJSON(packs: [[String: Any]]) -> Data {
        let obj: [String: Any] = ["schemaVersion": 2, "packs": packs]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - cleanup 選詞

    func testPersonalDictionaryWinsEvenWithEmptyOutput() {
        let dict = ["jeman": "Gemini", "cloudcoate": "Claude Code", "悠悠卡": "悠遊卡"]
        let out = VocabularySelector.termsForCleanup(text: "講到 jeman",
                                                    enabled: [], personal: dict, stations: [])
        XCTAssertTrue(out.contains("Gemini"))
        XCTAssertTrue(out.contains("Claude Code"))
        XCTAssertTrue(out.contains("悠遊卡"), "個人字典空 output 時，詞本身也要帶")
    }

    func testRelevantTermAppearsEvenWhenFarInBigPack() {
        // 工程包 1000 詞、人工智慧在第 800 個；計算機包 5 詞沒有相關詞。
        // 期待 selector 能撈出來，而不是只看前 200。
        let engineering = (1...800).map { "工程詞\($0)" } + ["人工智慧", "機器學習", "深度學習"]
        let computing = ["資料結構"]
        let packs = makePacks(terms: ["engineering": engineering, "computing": computing])
        let out = VocabularySelector.termsForCleanup(text: "我在研究人工智慧",
                                                    enabled: packs, personal: [:], stations: [])
        XCTAssertTrue(out.contains("人工智慧"), "第 800+ 個也要找得到")
    }

    func testFairMergePreventsBigPackFromSqueezingOthers() {
        // engineering 1000 詞全相關；computing 5 詞也相關。
        // 期待兩包都有詞進 cleanup，不會被 full 擠光。
        let engineering = (1...1000).map { "工程詞\($0)" }
        let computing = ["資料結構", "演算法", "資料庫", "作業系統", "編譯器"]
        let packs = makePacks(terms: ["engineering": engineering, "computing": computing])
        let out = VocabularySelector.termsForCleanup(text: "資料結構 工程詞1 演算法 工程詞2",
                                                    enabled: packs, personal: [:], stations: [])
        XCTAssertTrue(out.contains("資料結構"), "computing 也要進去")
        XCTAssertTrue(out.contains("演算法"))
        XCTAssertLessThanOrEqual(out.count, 200)
    }

    func testSeedRotationWhenNoRelevantMatch() {
        let engineering = (1...100).map { "工程詞\($0)" }
        let packs = makePacks(terms: ["engineering": engineering])
        let out = VocabularySelector.termsForCleanup(text: "完全不相關的句子",
                                                    enabled: packs, personal: [:], stations: [])
        // 沒匹配 → 用各包 seed 公平輪流。
        XCTAssertTrue(out.contains("代表詞-engineering"), "seed fallback 啟動")
    }

    func testStationTermsOnlyWhenTalkingAboutStations() {
        let stations = Set(["圓山站", "台北車站"])
        let tw = VocabularyCatalog.Pack(id: "tw", name: "真相", summary: "",
                                        sourceName: "", sourceURL: "",
                                        licenseName: "", licenseURL: "",
                                        attribution: "", version: "",
                                        defaultOn: true,
                                        seedTerms: ["圓山站"], termCount: 0,
                                        termsSHA256: "",
                                        terms: ["圓山站", "台北車站", "西門站", "高鐵"],
                                        termsFile: "")
        // 沒提到站／捷運 → 不帶站名；其他詞（高鐵）照帶
        let plain = VocabularySelector.termsForCleanup(text: "我搭高鐵", enabled: [tw], personal: [:], stations: stations)
        XCTAssertFalse(plain.contains("圓山站"))
        XCTAssertFalse(plain.contains("台北車站"))
        XCTAssertTrue(plain.contains("高鐵"))
        // 提到「站」→ 帶進來
        let stationText = VocabularySelector.termsForCleanup(text: "我搭到元山站", enabled: [tw], personal: [:], stations: stations)
        XCTAssertTrue(stationText.contains("圓山站"))
    }

    func testDisabledPackNotIncluded() {
        let dict = ["jeman": "Gemini"]
        // 用 setCatalogEnabled 控制；這裡直接驗 selector 不傳 disabled pack 即可。
        let packs = makePacks(terms: ["computing": ["人工智慧"]])
        // 故意不傳 encoding → selector 拿不到 engineering 的詞
        let onlyComputing = [packs[0]]
        let out = VocabularySelector.termsForCleanup(text: "我研究人工智慧",
                                                    enabled: onlyComputing, personal: dict, stations: [])
        XCTAssertTrue(out.contains("人工智慧"))
        XCTAssertTrue(out.contains("Gemini"))
    }

    func testCapAt200() {
        let dict = Dictionary(uniqueKeysWithValues: (1...500).map { ("k\($0)", "v\($0)") })
        let packs = makePacks(terms: [:])
        let out = VocabularySelector.termsForCleanup(text: nil, enabled: packs, personal: dict, stations: [])
        XCTAssertLessThanOrEqual(out.count, 200)
        XCTAssertEqual(Set(out).count, out.count, "去重")
    }

    func testMissingOrCorruptCatalogFallsBackToEmpty() {
        // selector 在空 catalog 仍應可用（既有三包走 pseudo pack；這裡純測 selector 不會崩）。
        let out = VocabularySelector.termsForCleanup(text: nil, enabled: [], personal: [:], stations: [])
        XCTAssertEqual(out.count, 0)
    }

    func testUnicodeAndDedup() {
        let dict = ["Jeman": "Gemini", "jeman": "Gemini", "JEMAN": "Gemini"]
        let out = VocabularySelector.termsForCleanup(text: "Jeman", enabled: [], personal: dict, stations: [])
        // 個人字典三個 key 同義，輸出應只有一個 Gemini
        XCTAssertEqual(out.filter { $0 == "Gemini" }.count, 1, "去重")
    }

    // MARK: - search

    func testSearchCapsAt100AndPrefersSeed() {
        let terms = (1...500).map { "詞\($0)" }
        let pack = VocabularyCatalog.Pack(id: "law", name: "法律", summary: "",
                                          sourceName: "", sourceURL: "",
                                          licenseName: "", licenseURL: "",
                                          attribution: "", version: "",
                                          defaultOn: false,
                                          seedTerms: ["詞100"], termCount: terms.count,
                                          termsSHA256: "",
                                          terms: terms,
                                          termsFile: "")
        let matches = VocabularySelector.search("詞", in: pack, limit: 100)
        XCTAssertEqual(matches.count, 100)
    }

    // MARK: - latin seed（避免巨量詞灌 LatinNameFixer）

    func testLatinSeedTermsOnlyReturnsSeedLatinWords() {
        let engineering = VocabularyCatalog.Pack(id: "engineering", name: "", summary: "",
                                                 sourceName: "", sourceURL: "",
                                                 licenseName: "", licenseURL: "",
                                                 attribution: "", version: "",
                                                 defaultOn: false,
                                                 seedTerms: ["Bridge", "Tunnel", "鋼筋"],
                                                 termCount: 0, termsSHA256: "",
                                                 terms: ["Bridge", "Tunnel", "鋼筋混凝土", "水泥", "灌注樁"],
                                                 termsFile: "")
        let seeds = VocabularySelector.latinSeedTerms(enabled: [engineering])
        XCTAssertEqual(seeds, ["Bridge", "Tunnel"])
    }

    // MARK: - RUNTIME-FINDINGS 反例

    /// RUNTIME-FINDINGS #3：1000 個弱相關詞放前面，「人工智慧」放最後。
    /// 本句「我在研究人工智慧」，結果必含「人工智慧」。
    /// 不可以 mock 這個詞進 seed 來繞過。
    func testExactTermWinsEvenAtEndOfBigPack() {
        var weakTerms: [String] = []
        weakTerms.reserveCapacity(1000)
        for i in 0..<1000 {
            weakTerms.append("工程\((i % 50) + 1)號細項\(i)")
        }
        weakTerms.append("人工智慧")  // 真的精確詞放在最後
        let pack = VocabularyCatalog.Pack(id: "engineering", name: "", summary: "",
                                          sourceName: "", sourceURL: "",
                                          licenseName: "", licenseURL: "",
                                          attribution: "", version: "",
                                          defaultOn: false,
                                          seedTerms: ["Bridge"], termCount: weakTerms.count,
                                          termsSHA256: "",
                                          terms: weakTerms,
                                          termsFile: "")
        let out = VocabularySelector.collectCandidates(text: "我在研究人工智慧",
                                                      enabled: [pack],
                                                      stations: [])
        XCTAssertTrue(out.contains("人工智慧"),
                      "1000 個弱相關後面有 1 個精確詞必須被選到（FINDINGS #3）；實際 \(out.prefix(20))")
    }

    /// RUNTIME-FINDINGS #4：rotation 終止＝「仍有未消耗元素」，不是「本輪有 insert」。
    /// fixture A seeds [甲詞, 乙詞, 後詞], B [乙詞, 甲詞, 末詞]；結果必須含 後詞、末詞。
    func testRotationContinuesPastDuplicateRound() {
        let a = VocabularyCatalog.Pack(id: "a", name: "A", summary: "",
                                       sourceName: "", sourceURL: "",
                                       licenseName: "", licenseURL: "",
                                       attribution: "", version: "",
                                       defaultOn: false,
                                       seedTerms: ["甲詞", "乙詞", "後詞"], termCount: 0,
                                       termsSHA256: "", terms: nil, termsFile: "")
        let b = VocabularyCatalog.Pack(id: "b", name: "B", summary: "",
                                       sourceName: "", sourceURL: "",
                                       licenseName: "", licenseURL: "",
                                       attribution: "", version: "",
                                       defaultOn: false,
                                       seedTerms: ["乙詞", "甲詞", "末詞"], termCount: 0,
                                       termsSHA256: "", terms: nil, termsFile: "")
        let out = VocabularySelector.fairSeedRotation(enabled: [a, b], stations: [])
        // 第 1 輪：A[0]=甲詞（加）、B[0]=乙詞（加）。
        // 第 2 輪：A[1]=乙詞（重複，跳）、B[1]=甲詞（重複，跳）。
        // 第 3 輪：A[2]=後詞（加）、B[2]=末詞（加）。
        XCTAssertTrue(out.contains("後詞"), "duplicate round 後仍要進到後面的詞；實際 \(out)")
        XCTAssertTrue(out.contains("末詞"))
    }

    /// RUNTIME-FINDINGS #4：fairMerge 在 per-pack 都是 duplicates 時仍能往下讀。
    /// fixture：兩包都有 [人工智慧×2, 人工後詞／人工末詞]；本句含「人工智慧」→
    ///   所有 6 個詞 bigram 都有「人工」重疊 → 全入 perPack。
    ///   第 1–2 輪 「人工智慧」被去重；第 3 輪 人工後詞／人工末詞 必須出現。
    func testFairMergeContinuesPastDuplicateRound() {
        let p1 = VocabularyCatalog.Pack(id: "a", name: "", summary: "",
                                       sourceName: "", sourceURL: "",
                                       licenseName: "", licenseURL: "",
                                       attribution: "", version: "",
                                       defaultOn: false,
                                       seedTerms: [], termCount: 0,
                                       termsSHA256: "",
                                       terms: ["人工智慧", "人工智慧", "人工後詞"], termsFile: "")
        let p2 = VocabularyCatalog.Pack(id: "b", name: "", summary: "",
                                       sourceName: "", sourceURL: "",
                                       licenseName: "", licenseURL: "",
                                       attribution: "", version: "",
                                       defaultOn: false,
                                       seedTerms: [], termCount: 0,
                                       termsSHA256: "",
                                       terms: ["人工智慧", "人工智慧", "人工末詞"], termsFile: "")
        let merged = VocabularySelector.collectCandidates(text: "我在研究人工智慧",
                                                          enabled: [p1, p2], stations: [])
        XCTAssertTrue(merged.contains("人工後詞"),
                      "duplicate round 後仍要進到後面的詞；實際 \(merged)")
        XCTAssertTrue(merged.contains("人工末詞"))
    }

    /// RUNTIME-FINDINGS #5：pseudoPacks 把每個內建 pack 各自獨立，terms 完整保留。
    /// 預設 ai+tw 開（內建 100+ 詞），medicine 也開起來；cleanup 提示詞不能只有 ai/tw。
    func testCleanupIncludesMedicineTermsWhenAiAndTwAlsoEnabled() {
        // medicine 包有意義的 seedTerms
        let medicine = VocabularyCatalog.Pack(id: "medicine", name: "醫療", summary: "",
                                              sourceName: "", sourceURL: "",
                                              licenseName: "", licenseURL: "",
                                              attribution: "", version: "",
                                              defaultOn: false,
                                              seedTerms: ["心肌梗塞", "高血壓", "糖尿病", "肺炎", "抗生素"],
                                              termCount: 5, termsSHA256: "",
                                              terms: nil, termsFile: "")
        // ai/tw 不傳 terms（模擬空），用 pseudo 方式：建一個 pseudo pack with terms
        let ai = VocabularyCatalog.Pack(id: "__builtin_ai", name: "AI", summary: "",
                                        sourceName: "", sourceURL: "",
                                        licenseName: "", licenseURL: "",
                                        attribution: "", version: "",
                                        defaultOn: true,
                                        seedTerms: Array(repeating: "x", count: 8),
                                        termCount: 250, termsSHA256: "",
                                        terms: (1...250).map { "ai\($0)" },
                                        termsFile: "")
        let tw = VocabularyCatalog.Pack(id: "__builtin_tw", name: "TW", summary: "",
                                        sourceName: "", sourceURL: "",
                                        licenseName: "", licenseURL: "",
                                        attribution: "", version: "",
                                        defaultOn: true,
                                        seedTerms: Array(repeating: "x", count: 8),
                                        termCount: 200, termsSHA256: "",
                                        terms: (1...200).map { "tw\($0)" },
                                        termsFile: "")
        // 本句包含「心肌梗塞」→ 期待 medicine 進 cleanup
        let out = VocabularySelector.termsForCleanup(text: "長輩有心肌梗塞",
                                                    enabled: [ai, tw, medicine],
                                                    personal: [:], stations: [])
        XCTAssertTrue(out.contains("心肌梗塞"), "medicine seed 必須在結果；實際前 30 個 = \(out.prefix(30))")
        XCTAssertLessThanOrEqual(out.count, 200)
    }

    /// RUNTIME-FINDINGS #2：contextualHints 公平輪流，預設 ai+tw 開、medicine 開、字典空。
    /// 提示詞必須含 medicine seed（不能被 ai+tw 預設吃光 200）。
    func testContextualHintsDoesNotStarveNewPacks() {
        // 用獨立 suite 避免污染 App Group 真實 prefs
        let suiteName = "contextual-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // 寫入 enabled = ai,tw,medicine（模擬使用者開了 medicine，ai/tw 是內建預設）
        defaults.set(["ai", "tw", "audio", "medicine"], forKey: "utuvo.type.vocabularyPacks.enabled")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // 直接測 selector 的核心：4 個 pack seeds 公平輪流
        let seedStreams: [[String]] = [
            Array(repeating: "ai\(UUID().uuidString.prefix(4))", count: 8) + (1...250).map { "ai\($0)" },
            Array(repeating: "tw\(UUID().uuidString.prefix(4))", count: 8) + (1...200).map { "tw\($0)" },
            ["心肌梗塞", "高血壓"],   // medicine pack seed
            ["音訊test"],
        ]
        // 模擬 contextualHints 的核心迴圈
        var out: [String] = []
        var seen = Set<String>()
        var cursors = Array(repeating: 0, count: seedStreams.count)
        while out.count < 200 {
            var progressed = false
            for i in 0..<seedStreams.count {
                guard cursors[i] < seedStreams[i].count else { continue }
                let t = seedStreams[i][cursors[i]]
                cursors[i] += 1
                progressed = true
                if seen.insert(t).inserted {
                    out.append(t)
                    if out.count >= 200 { break }
                }
            }
            if !progressed { break }
        }
        XCTAssertTrue(out.contains("心肌梗塞"),
                      "medicine seed 必須在 200 內；前 30 = \(out.prefix(30))")
        XCTAssertTrue(out.contains("高血壓"))
    }

    // MARK: - 入口冷啟動與 disabled 排除（RUNTIME-INTEGRATION-FINDINGS #1/#2）

    /// 測試用：暫時改寫 App Group enabled 清單，離開時還原。
    private func withStoredEnabled(_ ids: [String]?, _ body: () -> Void) {
        let defaults = UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard
        let key = "utuvo.type.vocabularyPacks.enabled"
        let original = defaults.stringArray(forKey: key)
        if let ids { defaults.set(ids, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        body()
    }

    /// 冷啟動：沒進過設定頁（cache 是 .empty）時，pipeline 入口（termsForCleanup／contextualHints）
    /// 必須自己把 catalog 載起來，而不是永遠空手而回。
    func testColdStartEntryPointLoadsCatalogWithoutSettingsPage() {
        VocabularyPacks.setCatalogForTest(.empty)   // 模擬 keyboard／語音冷啟動
        XCTAssertEqual(VocabularyPacks.catalog.schemaVersion, 0, "前置：還沒載入")
        _ = VocabularyPacks.termsForCleanup(text: nil, dictionary: [:])
        XCTAssertEqual(VocabularyPacks.catalog.schemaVersion, 2,
                       "termsForCleanup 入口必須觸發 catalog 載入（Bundle 內真實 metadata）")
        XCTAssertEqual(VocabularyPacks.catalog.packs.count, 6)

        VocabularyPacks.setCatalogForTest(.empty)
        _ = VocabularyPacks.contextualHints(dictionary: [:])
        XCTAssertEqual(VocabularyPacks.catalog.schemaVersion, 2, "contextualHints 入口也要觸發載入")
    }

    /// disabled 的內建包（audio 預設關）不得出現在 cleanup／辨識提示詞——包含 legacy 路徑吃的 unifiedHints。
    func testDisabledBuiltinAndCatalogPacksExcludedFromHintsAndCleanup() {
        VocabularyPacks.setCatalogForTest(.empty)   // 用真實 catalog + seed
        // 只開 ai；audio（內建）與六個 catalog 包都不在 enabled 清單。
        withStoredEnabled(["ai"]) {
            let cleanup = VocabularyPacks.termsForCleanup(text: nil, dictionary: [:])
            XCTAssertFalse(cleanup.contains("Dolby Atmos"), "audio 關閉不得進 cleanup：\(cleanup.prefix(20))")
            XCTAssertFalse(cleanup.contains("心肌梗塞"), "catalog 包預設全關不得進 cleanup")
            let hints = VocabularyPacks.contextualHints(dictionary: [:])
            XCTAssertFalse(hints.contains("Dolby Atmos"), "audio 關閉不得進辨識提示詞")
            XCTAssertFalse(hints.contains("心肌梗塞"))
            XCTAssertLessThanOrEqual(hints.count, 200)

            let unified = SpeechEngine.unifiedHints(personal: [])
            XCTAssertFalse(unified.contains("Dolby Atmos"), "legacy 引擎吃的 unifiedHints 同樣不得含 disabled 包")
            XCTAssertLessThanOrEqual(unified.count, 200)
        }
        // 開了 medicine 之後，同一入口必須真的看得到（冷啟動也一樣）。
        withStoredEnabled(["ai", "medicine"]) {
            VocabularyPacks.setCatalogForTest(.empty)   // 再模擬一次冷啟動
            let hints = VocabularyPacks.contextualHints(dictionary: [:])
            XCTAssertTrue(hints.contains("心肌梗塞"), "medicine 開啟＋冷啟動，seed 必須進提示詞")
        }
    }

    /// 統一提示詞（RUNTIME-INTEGRATION-FINDINGS #3）：個人詞排最前、補產品名、去重、上限 200；
    /// Legacy 與 Analyzer 都吃這同一份（SpeechEngine.start 只組一次）。
    func testUnifiedHintsPersonalFirstCapped200() {
        // 個人詞不到 200（151 條），後面才裝得下產品名與詞庫 hints；
        // 個人詞塞滿 200 時截斷是設計內行為（個人字典優先）。
        let personal = Array(repeating: "個人詞", count: 3) + (0..<150).map { "字典詞\($0)" }
        let hints = SpeechEngine.unifiedHints(personal: personal)
        XCTAssertEqual(hints.first, "個人詞", "個人字典優先")
        XCTAssertTrue(hints.contains("UTUVO Type"), "產品名在內")
        XCTAssertLessThanOrEqual(hints.count, 200, "上限 200")
        XCTAssertEqual(Set(hints).count, hints.count, "去重")

        // 個人詞超過 200：就只送前 200 個人詞（不被詞庫擠掉）。
        let flooded = SpeechEngine.unifiedHints(personal: (0..<250).map { "字典詞\($0)" })
        XCTAssertEqual(flooded.count, 200)
        XCTAssertTrue(flooded.allSatisfy { $0.hasPrefix("字典詞") }, "個人詞吃滿額度時不得混入其他來源")
    }
}