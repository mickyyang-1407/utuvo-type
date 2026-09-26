import XCTest
@testable import UTUVOTypeiOS

final class CleanupVocabularyLatencyTests: XCTestCase {
    func testExactMembershipDifferentialAcrossUnicodeAndBounds() {
        let atoms = ["a", "é", "e\u{301}", "中", "文", "👨‍👩‍👧‍👦", "👨", "🇹🇼", "✈️", "✈", "\r\n", "\n", " "]
        var queries = atoms + ["", String(repeating: "甲", count: 41), String(repeating: "甲", count: 1_025), "a" + String(repeating: "\u{301}", count: 33_000)]
        for a in atoms { for b in atoms { queries.append(a + b) } }
        let terms = atoms + ["", "\u{301}", "中華", String(repeating: "甲", count: 41)]
        for query in queries {
            let index = CleanupExactMatches(query)
            for term in terms + [query] {
                XCTAssertEqual(index.contains(term), query.contains(term), "query=\(query.prefix(8)), term=\(term.prefix(8))")
                let overlap = BigramOverlap.bigramsUInt64(of: query), latin = LatinTokens.tokens(of: query)
                XCTAssertEqual(TermScanner.score(term: term, overlap: overlap, latin: latin, checkCJK: !overlap.isEmpty, checkLatin: !latin.isEmpty, text: query, exactMatches: index),
                               TermScanner.score(term: term, overlap: overlap, latin: latin, checkCJK: !overlap.isEmpty, checkLatin: !latin.isEmpty, text: query))
            }
        }
    }

    func testCompleteCandidateOrderAndPersonalStationRules() {
        let terms = (0..<100).map { "人工\($0)" } + ["人工智慧", "圓山站", "Gemini", "é", "e\u{301}", "✈️"]
        let pack = VocabularyCatalog.Pack(id: "fixture", name: "fixture", summary: "", sourceName: "", sourceURL: "", licenseName: "", licenseURL: "", attribution: "", version: "1", defaultOn: false, seedTerms: ["種子"], termCount: terms.count, termsSHA256: "", terms: terms, termsFile: "fixture.txt")
        for query in ["人工智慧 Gemini", "圓山站人工智慧", "飛機✈️人工 e\u{301}", String(repeating: "人工智慧", count: 300)] {
            let overlap = BigramOverlap.bigramsUInt64(of: query), latin = LatinTokens.tokens(of: query)
            let expected = terms.filter { query.contains("站") || $0 != "圓山站" }.map { term in
                (term, TermScanner.score(term: term, overlap: overlap, latin: latin, checkCJK: !overlap.isEmpty, checkLatin: !latin.isEmpty, text: query))
            }.filter { $0.1 > 0 }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.count != $1.0.count { return $0.0.count < $1.0.count }
                return $0.0 < $1.0
            }.prefix(50).map(\.0)
            var seen = Set<String>()
            XCTAssertEqual(VocabularySelector.collectCandidates(text: query, enabled: [pack], stations: ["圓山站"]), expected.filter { seen.insert($0).inserted })
            let result = VocabularySelector.termsForCleanup(text: query, enabled: [pack], personal: ["typo": "PersonalFixture"], stations: ["圓山站"])
            XCTAssertEqual(result.first, "PersonalFixture")
            if query.contains("人工智慧") { XCTAssertTrue(result.contains("人工智慧")) } // Exact final term survives the full scan.
        }
        XCTAssertEqual(VocabularySelector.termsForCleanup(text: "人工智慧", enabled: [], personal: ["typo": "PersonalFixture"], stations: []), ["PersonalFixture", "typo"])
    }
}
