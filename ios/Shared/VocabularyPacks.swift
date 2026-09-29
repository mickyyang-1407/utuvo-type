import Foundation

/// 詞庫包（2026-09-20 Micky：「像百度、搜狗那樣有專門字典可以加」；實測 Gemini→Jamin、ChatGPT→Chit GPT、
/// Claude Code→cloudcoate、Perplexity→rprecity）。開著的詞庫三個用途：
/// 1. 交給辨識器當提示詞（一開始就比較容易聽對）；
/// 2. 交給智慧整理當「這位使用者常用的專有名詞」（大模型把 Jeman 改成 Gemini）；
/// 3. 使用者自己匯入的詞（一行一個，或「聽到→改成」）寫進個人字典。
///
/// 2026-09-20 runtime 票（CONTRACT-V2）：
/// - 內建三包（ai／tw／audio）保留（沿用既有 defaults 與使用者設定）；
/// - 新增六個 catalog 詞庫（資訊、醫療、財經、法律、工程、音樂音訊），預設全關，使用者明確開啟後才生效；
/// - catalog 來源：`Bundle.main/vocabulary/catalog.json` + `vocabulary/{id}.txt`；
/// - 啟動時只讀 metadata，terms 透過 `BundlePackTermsSource` 依使用情境（cleanup 選詞／UI 搜尋）延遲載入；
/// - keyboard extension 不會因為這個機制而撐大記憶體（只 seed／metadata 進去）。
enum VocabularyPacks {
    /// 內建詞庫（不來自 catalog.json；保留既有 ai／tw／audio 行為）。
    struct Pack: Identifiable, Sendable {
        let id: String
        let name: String
        let summary: String
        let terms: [String]
        let defaultOn: Bool
        /// 併入 selector 時當 seedTerms 的詞數（站名先排除；站名只在提到站／捷運時經相關度帶入）。
        var seedCount: Int = 8
    }

    static let all: [Pack] = [
        Pack(id: "ai", name: String(localized: "AI 與科技"), summary: "Gemini、ChatGPT、Claude、Perplexity…",
             terms: ["Gemini", "Google Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code", "Anthropic", "Perplexity",
                     // 2026-09-20 實機：公司名講出來會變成 AppleNVidia／MiniMax／GLMKimi，詞庫沒有就救不回來
                     "Apple", "Google", "Microsoft", "Amazon", "Meta", "Tesla", "Samsung", "Intel", "AMD", "Sora",
                     "MiniMax", "GLM", "Zhipu", "Moonshot", "Doubao", "Hunyuan", "Mistral", "Cohere", "Whisper",
                     "Ollama", "Hugging Face", "Vercel", "Cloudflare", "Supabase", "Xcode", "Kotlin", "SwiftUI",
                     "session", "token", "LLM", "MCP", "SDK", "CLI", "repo", "commit",
                     "Copilot", "GitHub", "Cursor", "Codex", "Midjourney", "Stable Diffusion", "DeepSeek", "Qwen", "Llama",
                     "Grok", "Kimi", "Typeless", "Chatterfly", "Notion", "Figma", "Canva", "Slack", "Discord", "Telegram",
                     "LINE", "Threads", "Instagram", "Facebook", "YouTube", "TikTok", "iPhone", "iPad", "MacBook",
                     "Apple Intelligence", "Siri", "Android", "Pixel", "NVIDIA", "TSMC", "API", "Prompt", "Vibe Coding"],
             defaultOn: true),
        Pack(id: "tw", name: String(localized: "台灣地名與交通"), summary: "捷運站名、西門町、南崁…",
             terms: TaiwanPlaces.contextualStrings + ["西門町", "南崁", "蘆洲", "板橋", "信義區", "台北車站", "桃園機場", "高鐵",
                                                      "台鐵", "捷運", "悠遊卡", "一卡通", "捷安特", "全聯", "家樂福", "7-Eleven", "全家"],
             // 站名以外全帶（23bfd10 之前的行為）；前 8 詞原本全是站名，被站名過濾後整包歸零
             defaultOn: true, seedCount: .max),
        Pack(id: "audio", name: String(localized: "音樂與音訊製作"), summary: "Atmos、Pro Tools、stem、LUFS…",
             terms: ["Dolby Atmos", "Atmos", "Pro Tools", "Logic Pro", "Ableton", "Cubase", "Nuendo", "DaVinci Resolve",
                     "ADM", "BWF", "binaural", "stem", "stems", "LUFS", "True Peak", "bed", "object", "renderer",
                     "mixing", "mastering", "混音", "母帶", "分軌", "錄音室", "Tonmeister", "Apple Music", "Spotify"],
             defaultOn: false),
    ]

    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.com.utuvo.type") ?? .standard }
    private static let enabledKey = "utuvo.type.vocabularyPacks.enabled"

    // MARK: - catalog（測試可注入）

    /// app 啟動時載入一次 metadata，存進來供所有呼叫端使用。
    /// 解析失敗回傳 `.empty`，UI 與 pipeline 退回既有三包。
    /// RUNTIME-INTEGRATION-FINDINGS #1/#4：keyboard／語音冷啟動不會經過設定頁，
    /// 所有 pipeline 入口都得先 `ensureCatalogLoaded()`；用 lock 守住（主執行緒與辨識回呼都可能進來）。
    nonisolated(unsafe) private static var cachedCatalog: VocabularyCatalog.Catalog = .empty
    private static let catalogLock = NSLock()
    nonisolated(unsafe) static var termsSource: PackTermsSource = BundlePackTermsSource()

    /// 對外暴露已快取的 catalog（UI 顯示明細用）；只含 metadata。
    static var catalog: VocabularyCatalog.Catalog { catalogLock.lock(); defer { catalogLock.unlock() }; return cachedCatalog }

    /// 注入測試 seam：合成 fixture 直接放進來，不必碰 Bundle。
    static func setCatalogForTest(_ catalog: VocabularyCatalog.Catalog) {
        catalogLock.lock(); defer { catalogLock.unlock() }
        self.cachedCatalog = catalog
    }

    /// 注入測試 seam：合成 pack terms（id -> terms）。
    static func setTermsSourceForTest(_ source: PackTermsSource) {
        self.termsSource = source
    }

    /// 重新解析並快取 catalog（設定頁 onAppear 用）；失敗時維持原值（既有三包仍可用）。
    @discardableResult
    static func loadCatalog(from bundle: Bundle = .main) -> VocabularyCatalog.Catalog {
        catalogLock.lock(); defer { catalogLock.unlock() }
        if let c = try? VocabularyCatalog.load(from: bundle) { cachedCatalog = c }
        return cachedCatalog
    }

    /// pipeline 入口用：還沒載入過（仍是 `.empty`）才讀一次；之後直接用快取。
    /// 成功與否都只嘗試一次嗎？不——失敗維持 `.empty`，下次入口再試一次也便宜（metadata < 100 KB）。
    static func ensureCatalogLoaded(bundle: Bundle = .main) {
        catalogLock.lock()
        let loaded = cachedCatalog.schemaVersion != VocabularyCatalog.Catalog.empty.schemaVersion
        catalogLock.unlock()
        guard !loaded else { return }
        _ = loadCatalog(from: bundle)
    }

    /// 已開啟的 catalog 詞庫包 metadata。
    static func enabledCatalogPacks() -> [VocabularyCatalog.Pack] {
        ensureCatalogLoaded()
        return catalog.packs.filter { isCatalogPackEnabled($0.id, defaultOn: $0.defaultOn) }
    }

    /// 已開啟的 catalog 詞庫包 + 已載入 terms（呼叫端視需要觸發 lazy 載入）。
    /// - Parameter ensureLoaded: true ＝這次呼叫端要用 terms，先把所有 enabled 包的 terms 載入一次。
    static func enabledCatalogPacks(ensureLoaded: Bool) -> [VocabularyCatalog.Pack] {
        var packs = enabledCatalogPacks()
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

    private static func isCatalogPackEnabled(_ id: String, defaultOn: Bool) -> Bool {
        guard let stored = defaults.stringArray(forKey: enabledKey) else { return defaultOn }
        return stored.contains(id)
    }

    static func isEnabled(_ pack: Pack) -> Bool {
        guard let stored = defaults.stringArray(forKey: enabledKey) else { return pack.defaultOn }
        return stored.contains(pack.id)
    }

    static func setEnabled(_ pack: Pack, _ on: Bool) {
        mutateEnabled { ids in
            if on { ids.insert(pack.id) } else { ids.remove(pack.id) }
        }
    }

    static func setCatalogEnabled(_ pack: VocabularyCatalog.Pack, _ on: Bool) {
        mutateEnabled { ids in
            if on { ids.insert(pack.id) } else { ids.remove(pack.id) }
        }
    }

    /// 同時管內建三包與 catalog 六包（同一份 enabledKey，避免兩處不同步）。
    private static func mutateEnabled(_ change: (inout Set<String>) -> Void) {
        var ids = Set(all.filter(isEnabled).map(\.id))
        ids.formUnion(enabledCatalogPacks().map(\.id))
        change(&ids)
        defaults.set(Array(ids), forKey: enabledKey)
    }

    /// 內建詞庫已開詞（去重）。
    static var enabledTerms: [String] {
        var seen = Set<String>()
        return all.filter(isEnabled).flatMap(\.terms).filter { seen.insert($0).inserted }
    }

    /// 明細頁搜尋用：不管開／關都把【這一包】的完整詞表載入（只載指定的包，不動其他包）。
    /// RUNTIME-UI-FINDINGS：enabled 之前也必須能預覽／搜尋整包，不能只給 31–40 個 seed。
    static func catalogPackWithTermsLoaded(id: String) -> VocabularyCatalog.Pack? {
        ensureCatalogLoaded()
        guard var pack = catalog.pack(id: id) else { return nil }
        if pack.terms == nil {
            pack.terms = termsSource.readTermsFile(packID: id)
        }
        return pack
    }

    /// 給智慧整理的專有名詞：個人字典優先（output 空字串時詞本身也有效），
    /// 再從已開啟專業包依 bigram／latin token 相關度篩入，未匹配時各包 seedTerms 公平輪流補滿。
    /// 捷運站名只在提到「站／捷運」時帶。
    /// 上限 200，不讓提示詞太長。
    /// 真正觸發 lazy 載入（已開啟包的 terms 一次讀完，後續 pipeline 共享快取）。
    static func termsForCleanup(text: String? = nil, dictionary: [String: String] = DictionaryStore.shared.dictionary) -> [String] {
        let stations = Set(TaiwanPlaces.contextualStrings)
        // 已開啟 catalog 包＋觸發 lazy 載入；selector 內 terms == nil 表示未載入，自動跳過。
        let enabled = enabledCatalogPacks(ensureLoaded: true)
        // 內建三包併入 selector：以「完整 terms」當候選（不切前 8），
        // seedTerms 取各包前幾個代表詞，與六新包公平合併。
        let pseudo = pseudoPacks(stations: stations)
        return VocabularySelector.termsForCleanup(text: text,
                                                  enabled: enabled + pseudo,
                                                  personal: dictionary,
                                                  stations: stations)
    }

    /// 內建三包併入 selector（RUNTIME-FINDINGS #5）：
    /// 每個包都是一個獨立 pseudo pack，terms = 該包完整詞、seedTerms = 該包站名以外前 seedCount 個代表詞。
    /// 不再全部併成一個 pseudo pack，免得 ai+tw 預設全展開塞光 cleanup 提示詞。
    private static func pseudoPacks(stations: Set<String>) -> [VocabularyCatalog.Pack] {
        // RUNTIME-INTEGRATION-FINDINGS #2：只用「已開啟」的內建包；關掉的 audio 不得進 cleanup 提示詞。
        all.filter(isEnabled).map { builtIn in
            VocabularyCatalog.Pack(id: "__builtin_\(builtIn.id)",
                                   name: builtIn.name,
                                   summary: builtIn.summary,
                                   sourceName: "UTUVO Type", sourceURL: "",
                                   licenseName: "", licenseURL: "",
                                   attribution: "2026-09-20 整理", version: "builtin",
                                   defaultOn: builtIn.defaultOn,
                                   seedTerms: Array(builtIn.terms.lazy.filter { !stations.contains($0) }.prefix(builtIn.seedCount)),
                                   termCount: builtIn.terms.count,
                                   termsSHA256: "",
                                   terms: builtIn.terms,
                                   termsFile: "")
        }
    }

    /// 個人字典裡使用者要的寫法：有輸出寫法用輸出寫法；「詞彙」模式（輸出是空字串）用詞本身——與 contextualHints 同一條規則。
    /// 2026-09-25 量測：只取 values 時，設定頁「新增詞彙」加的 LemonSqueezy、Atmos 全被當成空字串濾掉，從沒進過這張表。
    static func personalTerms(dictionary: [String: String] = DictionaryStore.shared.dictionary) -> [String] {
        dictionary.map { $0.value.isEmpty ? $0.key : $0.value }
    }

    /// 給英文專名修正（LatinNameFixer）的比對目標：
    /// 個人字典的寫法、鍵盤讀到的聯絡人／文字替換、內建三包、catalog 各包 seedTerms。
    /// **不**載入 catalog 包的 terms（避免幾萬詞灌進 fuzzy 比對，CONTRACT-V2 §RUNTIME）。
    static func latinTermsForFixer(dictionary: [String: String] = DictionaryStore.shared.dictionary) -> [String] {
        var seen = Set<String>()
        let lexicon = LearnedVocabulary.defaults.stringArray(forKey: LearnedVocabulary.lexiconKey) ?? []
        let catalogSeeds = VocabularySelector.latinSeedTerms(enabled: enabledCatalogPacks())
        return (personalTerms(dictionary: dictionary) + enabledTerms + lexicon + catalogSeeds)
            .filter { $0.contains(where: { $0.isASCII && $0.isLetter }) }
            .filter { seen.insert($0).inserted }
    }

    /// 給辨識器的提示詞（個人字典優先，再補已開啟詞庫，上限 200）。
    ///
    /// RUNTIME-FINDINGS #2：不要先 append builtIn／先 append catalog seed。
    /// 個人字典先取，剩下額度從【內建三包 seed + 各 catalog pack seed】公平輪流，
    /// 不會讓 ai+tw 預設就吃光 200。
    /// 個人詞的 output 為空時詞本身也算；非空時用 output（語意錯誤映射見 RUNTIME-FINDINGS #5）。
    static func contextualHints(dictionary: [String: String] = DictionaryStore.shared.dictionary) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        // 個人字典：output 非空用 output，output 空用 source。
        for (k, v) in dictionary {
            let terms: [String]
            if v.isEmpty {
                terms = [k]
            } else {
                terms = [v]   // 不送 source，避免「錯誤拼字」進 hint
            }
            for t in terms where !t.isEmpty && seen.insert(t).inserted {
                out.append(t)
                if out.count >= 200 { return out }
            }
        }
        for t in LearnedVocabulary.lexicon where seen.insert(t).inserted {
            out.append(t)
            if out.count >= 200 { return out }
        }
        // 公平輪流：已開啟的內建三包全部 terms + 已開啟 catalog 六包 seedTerms。
        // RUNTIME-INTEGRATION-FINDINGS #2：all.map 改 all.filter(isEnabled)——關掉的包（如 audio）不得出聲。
        // 內建三包詞量 < 200，併入 round-robin 才不會被 ai+tw 預設獨佔。
        let seedStreams: [[String]] = all.filter(isEnabled).map(\.terms) + enabledCatalogPacks().map(\.seedTerms)
        var cursors = Array(repeating: 0, count: seedStreams.count)
        let hardCap = 200
        while out.count < hardCap {
            var progressed = false
            for i in 0..<seedStreams.count {
                guard cursors[i] < seedStreams[i].count else { continue }
                let t = seedStreams[i][cursors[i]]
                cursors[i] += 1
                progressed = true
                if seen.insert(t).inserted {
                    out.append(t)
                    if out.count >= hardCap { return out }
                }
            }
            if !progressed { break }
        }
        return out
    }

    /// 匯入：一行一個詞，或「聽到→改成」（也接受 -> 、=>、Tab）。回傳加了幾筆。
    @discardableResult
    static func importLines(_ text: String, into store: DictionaryStore = .shared) -> Int {
        var added = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var parts: [String] = []
            for sep in ["→", "->", "=>", "\t"] where line.contains(sep) {
                parts = line.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
                break
            }
            if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty {
                store.addTerm(source: parts[0], output: parts[1])
            } else if parts.isEmpty, line.count <= 40 {
                store.addTerm(source: line, output: "")
            } else { continue }
            added += 1
        }
        return added
    }
}

// MARK: - 六個 catalog id 的顯示名稱／摘要（在地化）

extension VocabularyCatalog.Pack {
    /// catalog.json 的 name／summary 只有來源語言（繁中）。
    /// 六個固定 id 走在地化字串（繁中＋簡中），未知 id 退回 JSON 原文；
    /// 來源授權（sourceName/licenseName/attribution）保持原文不翻（UI-FINDINGS：source attribution original）。
    var displayName: String {
        switch id {
        case "computing": return String(localized: "vocab.pack.computing.name")
        case "medicine": return String(localized: "vocab.pack.medicine.name")
        case "finance": return String(localized: "vocab.pack.finance.name")
        case "law": return String(localized: "vocab.pack.law.name")
        case "engineering": return String(localized: "vocab.pack.engineering.name")
        case "music": return String(localized: "vocab.pack.music.name")
        default: return name
        }
    }

    var displaySummary: String {
        switch id {
        case "computing": return String(localized: "vocab.pack.computing.summary")
        case "medicine": return String(localized: "vocab.pack.medicine.summary")
        case "finance": return String(localized: "vocab.pack.finance.summary")
        case "law": return String(localized: "vocab.pack.law.summary")
        case "engineering": return String(localized: "vocab.pack.engineering.summary")
        case "music": return String(localized: "vocab.pack.music.summary")
        default: return summary
        }
    }

    /// 列表列上的實際詞數（來自 metadata termCount，不是已載入 terms 的長度）。
    var displayTermCount: String {
        String(localized: "\(termCount) 詞")
    }
}