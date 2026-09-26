import Foundation

/// 詞庫目錄（2026-09-20 runtime 票，依 CONTRACT-V2.md 改 schema 2）：
/// app 啟動時只讀 metadata（catalog.json），terms 改成 `termsFile + termCount`；
/// 各包的真實詞表（computing.txt 等）只在需要做明細搜尋／cleanup 相關度篩選時才延遲讀取。
///
/// 與舊行為差別：
/// - metadata 與 terms 分檔，不再開機就把 40 萬詞全塞進記憶體；
/// - 各包 `terms` 與 `seedTerms` 只在載入後存在；未載入的包＝nil／空集合；
/// - 從固定 id 推導檔名（`id + ".txt"`）——禁止任意路徑讀檔，避免讀到正式 catalog 外的資源；
/// - 失敗安全退回既有三包（ai/tw/audio 在 VocabularyPacks 內獨立處理）。
///
/// 純函式：`decode` 不碰 IO；`Loader` 封裝實際讀檔並快取單包內容。
enum VocabularyCatalog {
    /// 來自 catalog.json metadata 的一包；`terms` 預設為 nil（未載入）。
    struct Pack: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let summary: String
        let sourceName: String
        let sourceURL: String
        let licenseName: String
        let licenseURL: String
        let attribution: String
        let version: String
        let defaultOn: Bool
        let seedTerms: [String]
        let termCount: Int
        let termsSHA256: String
        /// 真實詞表（讀過 `termsFile` 後才有；未讀＝nil）。UI 不應直接 map 此陣列。
        var terms: [String]?
        let termsFile: String
    }

    struct Catalog: Sendable, Equatable {
        let schemaVersion: Int
        let packs: [Pack]
        static let empty = Catalog(schemaVersion: 0, packs: [])
        func pack(id: String) -> Pack? { packs.first { $0.id == id } }
        /// 固定六包 id（CONTRACT-V2 §1）。
        static let knownIDs: [String] = ["computing", "medicine", "finance", "law", "engineering", "music"]
    }

    enum LoadError: Error, Equatable {
        case missingResource
        case malformedJSON
        case unsupportedSchema(Int)
    }

    /// 從 Bundle 載入 metadata。`Bundle.main` 找不到時試 `Bundle(for:)`（測試）。
    static func load(from bundle: Bundle = .main, resource: String = "vocabulary/catalog") throws -> Catalog {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw LoadError.missingResource
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// 純 JSON 解析（測試與合成 fixture 共用）。不會觸發任何詞表讀檔。
    static func decode(_ data: Data) throws -> Catalog {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let obj = any as? [String: Any] else { throw LoadError.malformedJSON }
        let schema = obj["schemaVersion"] as? Int ?? 0
        guard schema == 2 else { throw LoadError.unsupportedSchema(schema) }
        guard let arr = obj["packs"] as? [[String: Any]] else { throw LoadError.malformedJSON }
        var packs: [Pack] = []
        packs.reserveCapacity(arr.count)
        for raw in arr {
            guard let id = raw["id"] as? String,
                  let name = raw["name"] as? String else { continue }
            let summary = (raw["summary"] as? String) ?? ""
            let sourceName = (raw["sourceName"] as? String) ?? ""
            let sourceURL = (raw["sourceURL"] as? String) ?? ""
            let licenseName = (raw["licenseName"] as? String) ?? ""
            let licenseURL = (raw["licenseURL"] as? String) ?? ""
            let attribution = (raw["attribution"] as? String) ?? ""
            let version = (raw["version"] as? String) ?? ""
            let defaultOn = (raw["defaultOn"] as? Bool) ?? false
            let seedTerms = (raw["seedTerms"] as? [String]) ?? []
            let termCount = (raw["termCount"] as? Int) ?? 0
            let termsSHA256 = (raw["termsSHA256"] as? String) ?? ""
            let termsFile = (raw["termsFile"] as? String) ?? ""
            packs.append(Pack(id: id, name: name, summary: summary,
                              sourceName: sourceName, sourceURL: sourceURL,
                              licenseName: licenseName, licenseURL: licenseURL,
                              attribution: attribution, version: version,
                              defaultOn: defaultOn, seedTerms: seedTerms,
                              termCount: termCount, termsSHA256: termsSHA256,
                              terms: nil, termsFile: termsFile))
        }
        return Catalog(schemaVersion: schema, packs: packs)
    }
}

// MARK: - 延遲詞表載入（按需讀 .txt）

/// 詞表讀檔器：每包只讀一次，快取內容。
///
/// 安全要求（CONTRACT-V2 §「RUNTIME writer」）：
/// - 只准讀固定六包 `id + ".txt"`；未知 id／路徑含 `/`／副檔名不是 .txt 一律拒絕；
/// - 讀不到／解析失敗→回 nil，呼叫端退回既有三包。
///
/// 設計：不標 Sendable；VocabularyPacks 端有 lock 守住，且同一 process 內只在 MainActor
/// 使用（cleanup pipeline 由主執行緒呼叫）。需要跨 actor 傳遞時，呼叫端先同步。
protocol PackTermsSource {
    /// 讀 `id + ".txt"`；`id` 不在白名單、或檔案不存在，回 nil。
    func readTermsFile(packID: String) -> [String]?
}

final class BundlePackTermsSource: PackTermsSource, @unchecked Sendable {
    private let bundle: Bundle
    /// Bundle 內的 vocabulary 目錄。xcodegen 設為 folder reference 後，
    /// URL 會是 `vocabulary/catalog.json`／`vocabulary/computing.txt` 同層。
    private let subdirectory: String
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    init(bundle: Bundle = .main, subdirectory: String = "vocabulary") {
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
        // Preserve the catalog’s exact UTF-8 identity, including compatibility ideographs.
        var seen = Set<Data>()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 2–40 字元；拒絕不平衡括號、編號片段、純數字（CONTRACT-V2 DATA §seed 品質：分檔也吃同樣的清洗）。
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
    /// 寬鬆版（runtime 端不能假設 data 已 100% 乾淨，至少擋掉最明顯的）。
    /// `&` 是合法詞（AT&T世界網／H&E染色法／程式&時鐘板，Kimi review round 1）：
    /// curated txt 不做 HTML decoding，直接收；`<`／`>`／`\t` 仍拒。
    static func isCleanTerm(_ t: String) -> Bool {
        // Match the data builder’s Unicode scalar length, rather than grapheme clusters.
        guard (2...40).contains(t.unicodeScalars.count) else { return false }
        if t.contains("<") || t.contains(">") || t.contains("\t") { return false }
        // 不平衡括號：左右括號數量差超過 1 就丟。
        var open = 0
        for c in t {
            if c == "(" { open += 1 } else if c == ")" { open -= 1 }
            if open < 0 || open > 1 { return false }
        }
        if open != 0 { return false }
        return true
    }
}

// MARK: - 選詞（純函式，可獨立測試）

enum VocabularySelector {
    /// 結果上限。Legacy SFSpeechRecognizer / SpeechAnalyzer 都吃不下幾萬字；
    /// 個人字典優先，剩下額度從各包依 bigram／latin-token 相關度公平填入。
    static let cleanupTokenLimit = 200
    static let seedFallbackPerPack = 6

    /// 給智慧整理的專有名詞：個人字典的寫法優先（output 空字串時詞本身也有效），
    /// 再從所有已開啟專業包依「與本句相關」篩入，未匹配時用各包 seedTerms 公平輪流補滿。
    ///
    /// 純函式，可獨立測試。
    /// - Parameters:
    ///   - text: 本次逐字稿（決定 bigram 重疊方向；nil = 不維度處理）
    ///   - enabled: 已開啟的 catalog 包（含已 lazy 載入的 terms，否則 terms=nil 視為 seed-only）
    ///   - personal: 個人字典 [來源:輸出]（output 空字串時來源詞當作有效詞）
    ///   - stations: 站名集合（僅在 text 提到「站／捷運」時帶）
    ///   - limit: 結果上限（預設 200）
    static func termsForCleanup(text: String?,
                                enabled: [VocabularyCatalog.Pack],
                                personal: [String: String],
                                stations: Set<String>,
                                limit: Int = cleanupTokenLimit) -> [String] {
        // 個人字典：output 空字串時詞本身也有效。
        var personalTerms: [String] = []
        var seen = Set<String>()
        for (k, v) in personal {
            let candidates = v.isEmpty ? [k] : [v, k]
            for c in candidates where !c.isEmpty && seen.insert(c).inserted {
                personalTerms.append(c)
            }
        }
        var out: [String] = []
        out.reserveCapacity(limit)
        for t in personalTerms where out.count < limit { out.append(t) }
        if out.count >= limit { return Array(out.prefix(limit)) }
        // 從專業包依 bigram / latin token 相關度篩入；公平合併（CONTRACT-V2 RUNTIME §4）。
        let candidates = collectCandidates(text: text, enabled: enabled, stations: stations)
        for t in candidates where seen.insert(t).inserted && out.count < limit { out.append(t) }
        if out.count >= limit { return Array(out.prefix(limit)) }
        // 未匹配：用各包 seedTerms 公平輪流補到上限，避免 ai／tw 吃光。
        for t in fairSeedRotation(enabled: enabled, stations: stations) where seen.insert(t).inserted && out.count < limit {
            out.append(t)
        }
        return Array(out.prefix(limit))
    }

    /// 各包依 bigram／latin token 重疊分數排序，全局合併至上限。
    /// - 一個大包（如 engineering 10 萬詞）不能只因 match 多就把其他包擠掉——
    ///   每包取各自前 N，再 round-robin 公平合併。
    /// - **完整掃描**：不因前 N 個 match 命中就停止；就算第一萬個才是「人工智慧」也要算到。
    /// - exact-match 加分：本句出現某詞子字串時該詞優先；短精確詞優於長籠統詞。
    ///
    /// 熱迴圈最佳化（RUNTIME-PERF）：
    /// - 本句 CJK bigram 用 `Set<UInt64>`（codepoint1 << 32 | codepoint2），避免每個 term 重複建 `Set<String>`。
    /// - term 端沿 unicodeScalars 直接比對，無需切 Character 陣列。
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

    /// 公平合併：每包輪流抽一個。終止條件是「仍有未消耗元素」，不是「本輪有 insert」。
    /// 同一個詞跨包重複出現時，後包的可讀項目仍要輪進來（RUNTIME-FINDINGS #4）。
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

    /// 未匹配：用各包 seedTerms 公平輪流；終止條件同上（RUNTIME-FINDINGS #4）。
    static func fairSeedRotation(enabled: [VocabularyCatalog.Pack],
                                 stations: Set<String>) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var cursors = Array(repeating: 0, count: enabled.count)
        var maxSeedLen = enabled.map(\.seedTerms.count).max() ?? 0
        // 上限保護：seed 數量通常 < 40；超過這個數表示異常，提前結束。
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

    /// 給搜尋 UI：先比對 seed，再比對已載入的 terms；未載入時顯示提示並提示用戶回去開啟。
    /// 結果上限 100；單詞 2–40 字元（DATA-TICKET 限制）。
    static func search(_ query: String, in pack: VocabularyCatalog.Pack, limit: Int = 100) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var matches: [String] = []
        var seen = Set<String>()
        // seed 排前（代表詞），其餘依順序。
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

    /// 單詞相關度分數（RUNTIME-PERF 熱迴圈版）：
    /// term 不再每次呼叫 `BigramOverlap.bigrams(of:)` 建 String Set，改在 unicodeScalars 上
    /// 直接以 UInt64 bigram 與本句 Set 比對；latin 仍用 String Set（每詞 latin token 數 < 1，可接受）。
    private static func score(term: String, bigrams: Set<String>, latin: Set<String>, text: String) -> Int {
        return TermScanner.score(term: term,
                                 overlap: BigramOverlap.bigramsUInt64(of: text),
                                 latin: latin,
                                 checkCJK: !bigrams.isEmpty,
                                 checkLatin: !latin.isEmpty,
                                 text: text)
    }
}

/// 共享的單詞掃描器（swift / kotlin 各自實作；熱路徑）。
/// 整段用 unicodeScalars 掃描：同時撈 bigram overlap、標記 CJK／latin、預過濾無關詞。
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
        // 預過濾：純中文詞 vs 本句沒 bigram、純拉丁詞 vs 本句沒 latin
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
/// 兩種回傳形式：
/// - `bigrams(of:)` Set<String>（給舊 path + 測試用，字串 2-char）
/// - `bigramsUInt64(of:)` Set<UInt64>（給熱迴圈用，codepoint1<<32 | codepoint2）
enum BigramOverlap {
    static func bigrams(of text: String) -> Set<String> {
        var out = Set<String>()
        var lastCJK: Character? = nil
        for c in text {
            if isCJK(c) {
                if let prev = lastCJK {
                    out.insert(String([prev, c]))
                }
                lastCJK = c
            } else {
                lastCJK = nil
            }
        }
        return out
    }

    /// 熱迴圈版：把兩個 CJK codepoint 打包到 UInt64。Swift Set<UInt64> 是 hashable 的純整數，比 Set<String> 快。
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

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        return scalar.value >= 0x3400 && scalar.value <= 0x9FFF
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