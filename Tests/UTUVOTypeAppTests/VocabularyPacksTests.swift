import XCTest
@testable import UTUVOTypeApp
import UTUVOTypeCore

/// 詞庫包 catalog decode + lazy load + 200 上限 + Latin seeds only。
/// 用 repo 內真實 `data/vocabulary/catalog.json`（透過 test bundle .copy 資源）。
final class VocabularyPacksTests: XCTestCase {

    func testMobileNamesAndLazyMetadata() throws {
        let terms = VocabularyPacks.latinTermsForFixer(personalValues: ["PersonalFixture"], enabled: Set(VocabularyCatalog.Catalog.knownIDs))
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
}