import Foundation

/// 詞庫包設定（Mac 端 2026-09-22）：iOS 已上線六個 catalog 詞庫，Mac 補上相同機制。
///
/// 對齊重點：
/// - 同樣六包（資訊、醫療、財經、法律、工程、音樂音訊）由 catalog.json 提供；
/// - 內建三包（ai／tw／audio）保留 Mac 既有的 `dictionary.values` 行為（Mac 沒有用 Pack 形式裝載，
///   透過個人字典的 latin 詞當作 LatinNameFixer 目標），所以這裡只暴露 catalog 6 包；
/// - 啟動時只讀 metadata；terms 透過 `BundlePackTermsSource` 延遲載入（cleanup 選詞／UI 搜尋時才讀）；
/// - cleanup 提示詞上限 200，個人字典優先，再用 bigram／latin token 相關度篩入；
/// - LatinNameFixer 只用 seeds（不載 400k 詞）避免幾萬詞灌進 fuzzy 比對。
///
/// 設定存於 `utuvo.type.vocabularyPacks.enabled`（字串陣列）——既有 Mac 設定鍵不一樣，
/// 在 AppPreferences 內存讀。
enum VocabularyPacks {
    static let resourceBundle = Bundle.module
    // Small mobile AI/name lexicon, traced to ios/Shared/VocabularyPacks.swift (2026-09-22).
    // Academic catalog seedTerms are Chinese; do not claim they provide these English names.
    static let builtInLatinTerms = ["Gemini", "Google Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code",
        "Anthropic", "Perplexity", "Apple", "NVIDIA", "MiniMax", "GLM", "Kimi", "UTUVO", "UTUVO Type"]

    /// 注入測試 seam：合成 pack terms（id -> terms）。
    nonisolated(unsafe) static var termsSource: PackTermsSource = BundlePackTermsSource()

    /// 對外暴露已快取的 catalog（UI 顯示明細用）；只含 metadata。
    static var catalog: VocabularyCatalog.Catalog {
        lock.lock(); defer { lock.unlock() }
        return cachedCatalog
    }

    /// 重新解析並快取 catalog（設定頁 onAppear 用）；失敗時維持原值。
    @discardableResult
    static func loadCatalog(from bundle: Bundle = VocabularyPacks.resourceBundle) -> VocabularyCatalog.Catalog {
        lock.lock(); defer { lock.unlock() }
        if let c = try? VocabularyCatalog.load(from: bundle) { cachedCatalog = c }
        return cachedCatalog
    }

    /// pipeline 入口用：還沒載入過（仍是 `.empty`）才讀一次；之後直接用快取。
    static func ensureCatalogLoaded(bundle: Bundle = VocabularyPacks.resourceBundle) {
        lock.lock()
        let loaded = cachedCatalog.schemaVersion != VocabularyCatalog.Catalog.empty.schemaVersion
        lock.unlock()
        guard !loaded else { return }
        _ = loadCatalog(from: bundle)
    }

    /// 已開啟的 catalog 詞庫包 metadata（不觸發 terms 讀檔）。
    static func enabledCatalogPacks(enabled: Set<String>) -> [VocabularyCatalog.Pack] {
        ensureCatalogLoaded()
        return catalog.packs.filter { isCatalogPackEnabled($0, enabled: enabled) }
    }

    /// 已開啟的 catalog 詞庫包 + 已載入 terms（呼叫端視需要觸發 lazy 載入）。
    static func enabledCatalogPacks(enabled: Set<String>, ensureLoaded: Bool) -> [VocabularyCatalog.Pack] {
        var packs = enabledCatalogPacks(enabled: enabled)
        guard ensureLoaded else { return packs }
        for i in packs.indices {
            let id = packs[i].id
            if packs[i].terms == nil, let terms = termsSource.readTermsFile(packID: id) {
                packs[i] = VocabularyCatalog.Pack(id: packs[i].id, name: packs[i].name, summary: packs[i].summary,
                                                  sourceName: packs[i].sourceName, sourceURL: packs[i].sourceURL,
                                                  licenseName: packs[i].licenseName, licenseURL: packs[i].licenseURL,
                                                  attribution: packs[i].attribution, version: packs[i].version,
                                                  defaultOn: packs[i].defaultOn, seedTerms: packs[i].seedTerms,
                                                  termCount: packs[i].termCount, termsSHA256: packs[i].termsSHA256,
                                                  terms: terms, termsFile: packs[i].termsFile)
            }
        }
        return packs
    }

    static func isCatalogPackEnabled(_ pack: VocabularyCatalog.Pack, enabled: Set<String>) -> Bool {
        // 預設值也走這條路：使用者尚未明確開／關任何詞庫包時，讀取打包進去的 defaultOn。
        return enabled.contains(pack.id)
    }

    /// 明細頁搜尋用：不管開／關都把【這一包】的完整詞表載入。
    static func catalogPackWithTermsLoaded(id: String) -> VocabularyCatalog.Pack? {
        ensureCatalogLoaded()
        guard var pack = catalog.pack(id: id) else { return nil }
        if pack.terms == nil {
            pack.terms = termsSource.readTermsFile(packID: id)
        }
        return pack
    }

    /// 給英文專名修正（LatinNameFixer）的比對目標：
    /// 個人字典的寫法 + catalog 各包 seedTerms（拉丁字母子集）。
    /// 不載入 catalog 包的 terms（避免幾萬詞灌進 fuzzy 比對，CONTRACT-V2 §RUNTIME）。
    static func latinTermsForFixer(personalValues: [String], enabled: Set<String>) -> [String] {
        var seen = Set<String>()
        let catalogSeeds = VocabularySelector.latinSeedTerms(enabled: enabledCatalogPacks(enabled: enabled))
        var out: [String] = []
        for t in personalValues where t.contains(where: { $0.isASCII && $0.isLetter }) {
            if seen.insert(t).inserted { out.append(t) }
        }
        for t in builtInLatinTerms + catalogSeeds where seen.insert(t).inserted { out.append(t) }
        return out
    }

    /// Bounded ASR hints use canonical personal spelling and metadata seeds only.
    static func contextualHints(personal: [String: String], enabled: Set<String>, limit: Int = 200) -> [String] {
        var seen = Set<String>(), result: [String] = []
        for (source, output) in personal.sorted(by: { $0.key < $1.key }) {
            let term = output.isEmpty ? source : output
            if !term.isEmpty, seen.insert(term).inserted { result.append(term) }
            if result.count >= limit { return Array(result.prefix(max(0, limit))) }
        }
        let streams = [builtInLatinTerms] + enabledCatalogPacks(enabled: enabled).map(\.seedTerms)
        for index in 0..<(streams.map(\.count).max() ?? 0) {
            for stream in streams where stream.indices.contains(index) {
                if seen.insert(stream[index]).inserted { result.append(stream[index]) }
                if result.count >= limit { return Array(result.prefix(max(0, limit))) }
            }
        }
        return result
    }

    /// 給搜尋 UI：先比對 seed，再比對已載入的 terms；未載入時顯示提示。
    /// 結果上限 100；單詞 2–40 字元。
    static func search(_ query: String, in pack: VocabularyCatalog.Pack, limit: Int = 100) -> [String] {
        VocabularySelector.search(query, in: pack, limit: limit)
    }

    /// 給 cleanup 提示詞的選詞結果：個人字典優先，再用 bigram／latin 相關度從已開啟包篩入，
    /// 未匹配用各包 seedTerms 公平輪流補滿。上限 200，不讓提示詞太長。
    static func termsForCleanup(text: String?,
                                 personal: [String: String],
                                 enabled: Set<String>) -> [String] {
        let stations = Set(TaiwanPlaces.contextualStrings)
        let enabledPacks = enabledCatalogPacks(enabled: enabled, ensureLoaded: true)
        return VocabularySelector.termsForCleanup(text: text,
                                                  enabled: enabledPacks,
                                                  personal: personal,
                                                  stations: stations)
    }

    // MARK: - 私有的快取與同步

    nonisolated(unsafe) private static var cachedCatalog: VocabularyCatalog.Catalog = .empty
    private static let lock = NSLock()
}

// MARK: - 延遲詞表載入（按需讀 .txt）

/// 詞表讀檔器：每包只讀一次，快取內容。
protocol PackTermsSource: AnyObject {
    /// 讀 `id + ".txt"`；`id` 不在白名單、或檔案不存在，回 nil。
    func readTermsFile(packID: String) -> [String]?
}

final class BundlePackTermsSource: PackTermsSource, @unchecked Sendable {
    private let bundle: Bundle
    /// Bundle 內的 vocabulary 目錄。Mac SwiftPM 打包 `data/vocabulary/` 為資源，
    /// URL 為 `vocabulary/catalog.json`／`vocabulary/computing.txt` 同層。
    private let subdirectory: String
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    init(bundle: Bundle = VocabularyPacks.resourceBundle, subdirectory: String = "vocabulary") {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    func readTermsFile(packID: String) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[packID] { return hit }
        guard Self.isAllowedID(packID) else { return nil }
        guard let url = bundle.url(forResource: packID, withExtension: "txt", subdirectory: subdirectory) else {
            return nil
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var out: [String] = []
        out.reserveCapacity(text.count / 3)
        var seen = Set<Data>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isCleanTerm(t) else { continue }
            if seen.insert(Data(t.utf8)).inserted { out.append(t) }
        }
        cache[packID] = out
        return out
    }

    /// 只准六包固定 id，避免任意檔名讀入。
    static func isAllowedID(_ id: String) -> Bool {
        VocabularyCatalog.Catalog.knownIDs.contains(id)
    }

    /// 與 data writer 同樣的清洗：去 HTML／公式／控制字元／數字編號片段。
    static func isCleanTerm(_ t: String) -> Bool {
        guard (2...40).contains(t.unicodeScalars.count) else { return false }
        if t.contains("<") || t.contains(">") || t.contains("\t") { return false }
        var open = 0
        for c in t {
            if c == "(" { open += 1 } else if c == ")" { open -= 1 }
            if open < 0 || open > 1 { return false }
        }
        if open != 0 { return false }
        return true
    }
}

// MARK: - 選詞（純函式，可獨立測試；與 iOS 對齊）

enum VocabularySelector {
    static let cleanupTokenLimit = 200
    static let seedFallbackPerPack = 6

    /// 給智慧整理的專有名詞：個人字典優先，再用 bigram／latin 相關度從已開啟包篩入，
    /// 未匹配用各包 seedTerms 公平輪流補滿。上限預設 200。
    static func termsForCleanup(text: String?,
                                enabled: [VocabularyCatalog.Pack],
                                personal: [String: String],
                                stations: Set<String>,
                                limit: Int = cleanupTokenLimit) -> [String] {
        // 個人字典：output 空字串時詞本身也有效。
        var personalTerms: [String] = []
        var seen = Set<String>()
        for (k, v) in personal {
            let candidates = v.isEmpty ? [k] : [v]
            for c in candidates where !c.isEmpty && seen.insert(c).inserted {
                personalTerms.append(c)
            }
        }
        var out: [String] = []
        out.reserveCapacity(limit)
        for t in personalTerms where out.count < limit { out.append(t) }
        if out.count >= limit { return Array(out.prefix(limit)) }
        let candidates = collectCandidates(text: text, enabled: enabled, stations: stations)
        for t in candidates where seen.insert(t).inserted && out.count < limit { out.append(t) }
        if out.count >= limit { return Array(out.prefix(limit)) }
        for t in fairSeedRotation(enabled: enabled, stations: stations) where seen.insert(t).inserted && out.count < limit {
            out.append(t)
        }
        return Array(out.prefix(limit))
    }

    /// 各包依 bigram／latin token 重疊分數排序，全局合併至上限（公平 round-robin）。
    static func collectCandidates(text: String?,
                                 enabled: [VocabularyCatalog.Pack],
                                 stations: Set<String>) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let overlapUInt64 = BigramOverlap.bigramsUInt64(of: text)
        let latin = LatinTokens.tokens(of: text)
        guard !overlapUInt64.isEmpty || !latin.isEmpty else { return [] }
        let needsStations = text.contains("站") || text.contains("捷運")
        let checkCJK = !overlapUInt64.isEmpty
        let checkLatin = !latin.isEmpty
        if !checkCJK && !checkLatin { return [] }
        let exactMatches = CleanupExactMatches(text)
        let candidatesPerPack = 50
        var perPack: [[String]] = []
        perPack.reserveCapacity(enabled.count)
        for pack in enabled {
            guard let terms = pack.terms else { continue }
            var scored: [(term: String, score: Int)] = []
            for term in terms where !term.isEmpty {
                if !needsStations && stations.contains(term) { continue }
                let s = TermScanner.score(term: term,
                                          overlap: overlapUInt64,
                                          latin: latin,
                                          checkCJK: checkCJK,
                                          checkLatin: checkLatin,
                                          text: text,
                                          exactMatches: exactMatches)
                if s > 0 { scored.append((term, s)) }
            }
            scored.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.term.count != rhs.term.count { return lhs.term.count < rhs.term.count }
                return lhs.term < rhs.term
            }
            perPack.append(scored.prefix(candidatesPerPack).map(\.term))
        }
        return fairMerge(perPack)
    }

    /// 公平合併：每包輪流抽一個。
    private static func fairMerge(_ perPack: [[String]]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var cursors = Array(repeating: 0, count: perPack.count)
        while true {
            var progressed = false
            for i in 0..<perPack.count {
                guard cursors[i] < perPack[i].count else { continue }
                let t = perPack[i][cursors[i]]
                cursors[i] += 1
                progressed = true
                if seen.insert(t).inserted { out.append(t) }
            }
            if !progressed { break }
        }
        return out
    }

    /// 未匹配：用各包 seedTerms 公平輪流。
    static func fairSeedRotation(enabled: [VocabularyCatalog.Pack],
                                 stations: Set<String>) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var cursors = Array(repeating: 0, count: enabled.count)
        let maxSeedLen = enabled.map(\.seedTerms.count).max() ?? 0
        let hardCap = min(maxSeedLen, 80)
        while true {
            var progressed = false
            for i in 0..<enabled.count {
                guard cursors[i] < enabled[i].seedTerms.count else { continue }
                let s = enabled[i].seedTerms[cursors[i]]
                cursors[i] += 1
                progressed = true
                if stations.contains(s) { continue }
                if seen.insert(s).inserted { out.append(s) }
            }
            if !progressed { break }
            if cursors.allSatisfy({ $0 >= hardCap }) { break }
        }
        return out
    }

    /// 拉丁字母詞只給 `LatinNameFixer`：各包 seedTerms 的含拉丁字母子集。
    static func latinSeedTerms(enabled: [VocabularyCatalog.Pack]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for pack in enabled {
            for s in pack.seedTerms where s.contains(where: { $0.isASCII && $0.isLetter }) {
                if seen.insert(s).inserted { out.append(s) }
            }
        }
        return out
    }

    /// 給搜尋 UI：先比對 seed，再比對已載入的 terms。
    static func search(_ query: String, in pack: VocabularyCatalog.Pack, limit: Int = 100) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var matches: [String] = []
        var seen = Set<String>()
        for t in pack.seedTerms where t.contains(q) && seen.insert(t).inserted {
            matches.append(t)
            if matches.count >= limit { return matches }
        }
        if let terms = pack.terms {
            for t in terms where t.contains(q) && seen.insert(t).inserted {
                matches.append(t)
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }
}

/// 共享的單詞掃描器（swift／kotlin 各自實作；熱路徑）。
/// Per-query canonical-equivalent exact matches, bounded independently of pack size.
/// Character boundaries preserve String.contains semantics for combining marks / emoji.
struct CleanupExactMatches {
    private let text: String
    private let substrings: Set<Substring>?

    init(_ text: String) {
        self.text = text
        // At most 40,960 entries; unusually long input keeps the original exact search.
        guard text.utf8.count <= 65_536, text.count <= 1_024 else {
            substrings = nil
            return
        }
        var matches = Set<Substring>()
        for start in text.indices {
            var end = start
            for _ in 0..<40 {
                guard end < text.endIndex else { break }
                end = text.index(after: end)
                matches.insert(text[start..<end])
            }
        }
        substrings = matches
    }

    func contains(_ term: String) -> Bool {
        guard let substrings, !term.isEmpty, term.count <= 40 else {
            return text.contains(term)
        }
        return substrings.contains(term[...])
    }
}

enum TermScanner {
    static func score(term: String,
                      overlap: Set<UInt64>,
                      latin: Set<String>,
                      checkCJK: Bool,
                      checkLatin: Bool,
                      text: String,
                      exactMatches: CleanupExactMatches? = nil) -> Int {
        var s = 0
        var hasCJK = false
        var hasLatin = false
        var lastCJK: UInt32? = nil
        for scalar in term.unicodeScalars {
            let v = scalar.value
            if v >= 0x3400 && v <= 0x9FFF {
                hasCJK = true
                if let prev = lastCJK, checkCJK {
                    let key = (UInt64(prev) << 32) | UInt64(v)
                    if overlap.contains(key) { s += 2 }
                }
                lastCJK = v
            } else {
                lastCJK = nil
                if v < 128, scalar == Unicode.Scalar(0x41) || (v >= 0x41 && v <= 0x5A)
                          || (v >= 0x61 && v <= 0x7A) {
                    hasLatin = true
                }
            }
        }
        if hasCJK && !hasLatin && !checkCJK { return 0 }
        if hasLatin && !hasCJK && !checkLatin { return 0 }
        if hasLatin {
            let termTokens = LatinTokens.tokens(of: term)
            s += termTokens.intersection(latin).count
        }
        if exactMatches?.contains(term) ?? text.contains(term) { s += 10 }
        return s
    }
}

/// 簡單中文 bigram（不做斷詞；CJK 兩兩相連）。
enum BigramOverlap {
    static func bigramsUInt64(of text: String) -> Set<UInt64> {
        var out = Set<UInt64>()
        var last: UInt32? = nil
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x3400 && v <= 0x9FFF {
                if let prev = last {
                    out.insert((UInt64(prev) << 32) | UInt64(v))
                }
                last = v
            } else {
                last = nil
            }
        }
        return out
    }
}

/// 拉丁字母 token 切分（空白／標點）。
enum LatinTokens {
    static func tokens(of text: String) -> Set<String> {
        let parts = text.unicodeScalars.split { scalar in
            !(scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar)))
        }
        var out = Set<String>()
        for p in parts {
            let t = String(String.UnicodeScalarView(p)).lowercased()
            if t.count >= 2 { out.insert(t) }
        }
        return out
    }
}