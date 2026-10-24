import Foundation

/// 內建三包詞庫（ai／tw／audio）與辨識提示詞排序：Mac 的唯一 Swift 正本（asr-vocab-1，2026-10-22）。
///
/// - 詞表跟 Android `android/app/.../VocabularyPacks.kt` 的 `all` 同一份；`BuiltInVocabularyTests` 直接讀那個 .kt 檔逐詞比對，
///   改這裡就要一起改那裡（反之亦然）。
/// - iOS 目前還用自己的 `ios/Shared/VocabularyPacks.swift`（外部 PR 正在改那邊），之後再改用這份。
/// - 預設跟 iOS／Android 一樣：ai、tw 開，audio 關。開關存在同一份 enabled 集合裡（id 跟 catalog 六包不重疊）。
public enum BuiltInVocabulary {
    public struct Pack: Sendable, Equatable, Identifiable {
        public let id: String
        /// 列表上的範例詞（繁中、英文共用）。
        public let summary: String
        public let terms: [String]
        public let defaultOn: Bool
        /// 併入整理選詞（selector）時當 seedTerms 的詞數（站名先排除；站名只在提到站／捷運時經相關度帶入）。
        public let seedCount: Int

        public init(id: String, summary: String, terms: [String], defaultOn: Bool, seedCount: Int = 8) {
            self.id = id
            self.summary = summary
            self.terms = terms
            self.defaultOn = defaultOn
            self.seedCount = seedCount
        }
    }

    /// 自家產品名：不屬於任何一包、不受開關影響，一律排在個人字典後面（同 iOS `SpeechEngine.cloudHints`）。
    public static let productNames = ["UTUVO Type", "UTUVO"]

    /// 台北捷運站名（不含「站」）。跟 Android core `TaiwanPlaces.taipeiMRT`、iOS `TaiwanPlaces.taipeiMRT` 同一份。
    public static let taipeiMRT: [String] = [
        // 淡水信義線
        "淡水", "紅樹林", "竹圍", "關渡", "忠義", "復興崗", "北投", "新北投", "奇岩", "唭哩岸", "石牌", "明德", "芝山", "士林",
        "劍潭", "圓山", "民權西路", "雙連", "中山", "台北車站", "台大醫院", "中正紀念堂", "東門", "大安森林公園", "大安",
        "信義安和", "台北101", "世貿", "象山",
        // 松山新店線
        "松山", "南京三民", "台北小巨蛋", "南京復興", "松江南京", "北門", "西門", "小南門", "古亭", "台電大樓", "公館",
        "萬隆", "景美", "大坪林", "七張", "新店區公所", "新店", "小碧潭",
        // 板南線
        "頂埔", "永寧", "土城", "海山", "亞東醫院", "府中", "板橋", "新埔", "江子翠", "龍山寺", "善導寺", "忠孝新生",
        "忠孝復興", "忠孝敦化", "國父紀念館", "市政府", "永春", "後山埤", "昆陽", "南港", "南港展覽館",
        // 中和新蘆線
        "南勢角", "景安", "永安市場", "頂溪", "行天宮", "中山國小", "民權西路", "大橋頭", "台北橋", "菜寮", "三重",
        "先嗇宮", "頭前庄", "新莊", "輔大", "丹鳳", "迴龍", "三重國小", "三和國中", "徐匯中學", "三民高中", "蘆洲",
        // 文湖線
        "動物園", "木柵", "萬芳社區", "萬芳醫院", "辛亥", "麟光", "六張犁", "科技大樓", "中山國中", "松山機場", "大直",
        "劍南路", "西湖", "港墘", "文德", "內湖", "大湖公園", "葫洲", "東湖", "南港軟體園區",
        // 環狀線
        "十四張", "秀朗橋", "景平", "中和", "橋和", "中原", "板新", "新埔民生", "幸福", "新北產業園區",
    ]

    /// 「站名＋站」（去重、保留順序）。
    public static let stationNames: [String] = {
        var seen = Set<String>()
        return taipeiMRT.filter { seen.insert($0).inserted }.map { $0 + "站" }
    }()

    public static let ai = Pack(
        id: "ai", summary: "Gemini、ChatGPT、Claude、Perplexity…",
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
        defaultOn: true)

    public static let tw = Pack(
        id: "tw", summary: "捷運站名、西門町、南崁…",
        terms: stationNames + ["西門町", "南崁", "蘆洲", "板橋", "信義區", "台北車站", "桃園機場", "高鐵",
                               "台鐵", "捷運", "悠遊卡", "一卡通", "捷安特", "全聯", "家樂福", "7-Eleven", "全家"],
        // 站名以外全帶；前 8 詞原本全是站名，被站名過濾後整包歸零（同 iOS／Android）
        defaultOn: true, seedCount: .max)

    /// 2026-10-22 bench：Claude 把 AIFC 改成 AIFF、辨識聽成 ToneMaster／Special Audio → 補 Spatial Audio、AIFF、AIFC（Tonmeister 原本就有）。
    public static let audio = Pack(
        id: "audio", summary: "Atmos、Pro Tools、stem、LUFS…",
        terms: ["Dolby Atmos", "Atmos", "Pro Tools", "Logic Pro", "Ableton", "Cubase", "Nuendo", "DaVinci Resolve",
                "ADM", "BWF", "binaural", "stem", "stems", "LUFS", "True Peak", "bed", "object", "renderer",
                "mixing", "mastering", "混音", "母帶", "分軌", "錄音室", "Tonmeister", "Apple Music", "Spotify",
                "Spatial Audio", "AIFF", "AIFC"],
        defaultOn: false)

    public static let all: [Pack] = [ai, tw, audio]

    /// 三包的 id（跟 catalog 六包的 id 不重疊，可以放在同一份 enabled 集合）。
    public static let ids: Set<String> = Set(all.map(\.id))

    /// 預設開的包（ai、tw）。
    public static let defaultOnIDs: Set<String> = Set(all.filter(\.defaultOn).map(\.id))

    public static func pack(id: String) -> Pack? { all.first { $0.id == id } }

    /// 已開的內建包，照 `all` 的順序。
    public static func enabledPacks(_ enabled: Set<String>) -> [Pack] {
        all.filter { enabled.contains($0.id) }
    }

    /// 已開內建包的詞（去重，照 `all` 的順序）。
    public static func enabledTerms(_ enabled: Set<String>) -> [String] {
        var seen = Set<String>()
        return enabledPacks(enabled).flatMap(\.terms).filter { seen.insert($0).inserted }
    }

    /// Mac 英文專名修正（LatinNameFixer）從 2026-09-20 起就在用的 AI 名稱（實機聽成 Jamin／Chit GPT／AppleNVidia／GLMKimi）。
    /// ai 包開著才用。ai 包其他單字詞（Notion、Slack、Meta、session、token…）不進修正器：把常用英文字表
    /// （android/app/src/main/assets/english-words.txt 前 20,000 個）放進句子跑修正器，整個 ai 包會改到 296 個字
    /// （phone→iPhone、shop→Zhipu、stock→SDK、types→Typeless），舊 Mac 的 16 個（＝這 12 個＋多字詞＋產品名）是 100 個。
    public static let aiNameFixerTerms = ["Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Anthropic", "Perplexity",
                                          "Apple", "NVIDIA", "MiniMax", "GLM", "Kimi"]

    /// 包內的多字英文詞（Pro Tools、Claude Code、Spatial Audio）：夠長，加權距離不太會撞到一般英文字
    /// （同一份兩萬字表，三包的多字詞＋產品名只改到 protocols、prowls 兩個）。
    public static func isLatinPhrase(_ term: String) -> Bool {
        term.contains(" ") && term.contains { $0.isASCII && $0.isLetter }
    }

    /// Mac 本機整理版的英文專名修正目標（包內那部分）：ai 開著時的 `aiNameFixerTerms`＋已開各包的多字英文詞。
    /// 辨識提示詞與整理清單照用整包（`asrHints`、`enabledTerms`）。
    public static func fixerTerms(_ enabled: Set<String>) -> [String] {
        var seen = Set<String>()
        let names = enabled.contains(ai.id) ? aiNameFixerTerms : []
        return (names + enabledPacks(enabled).flatMap { $0.terms.filter(isLatinPhrase) }).filter { seen.insert($0).inserted }
    }

    /// 辨識提示詞的內建包順序：音訊 → AI → 其他內建包（同 iOS `prioritizedPackTerms`、Android `cloudHints`）。
    public static let hintPriority = ["audio", "ai"]

    public static func packsInHintOrder(_ enabled: Set<String>) -> [Pack] {
        enabledPacks(enabled).enumerated().sorted { lhs, rhs in
            let l = hintPriority.firstIndex(of: lhs.element.id) ?? hintPriority.count
            let r = hintPriority.firstIndex(of: rhs.element.id) ?? hintPriority.count
            return l != r ? l < r : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 不送進辨識提示詞的包內詞：使用者說「Type」，模型會被「Typeless」拉過去（pn05，asr-vocab-1 verifier）。
    /// 個人字典裡的詞照送（那是使用者自己要的）。
    public static let asrHintExclusions: Set<String> = ["Typeless"]

    /// 提示詞要不要轉台灣繁體：中文、而且不是簡體／新加坡（同 iOS `SpeechEngine.cloudHints`）。
    public static func usesTraditionalHints(language: String) -> Bool {
        let simplified = language.hasPrefix("zh-CN") || language.hasPrefix("zh-Hans") || language.hasPrefix("zh-SG")
        return language.hasPrefix("zh") && !simplified
    }

    /// 提示詞字形：中文聽寫、輸出選簡體（或語言本身是簡體）→ 簡體；其他中文 → 台灣繁體；非中文（含自動偵測）照原樣。
    public static func hintScript(language: String, simplifiedOutput: Bool) -> HintScript {
        guard language.hasPrefix("zh") else { return .asIs }
        return simplifiedOutput || !usesTraditionalHints(language: language) ? .simplified : .traditional
    }

    /// 辨識提示詞（Qwen hotwords、Groq Whisper prompt、百鍊、Apple 語音退路共用）：
    /// 個人字典 → 產品名 → 音訊包 → AI 包 → 其他內建包 → 目錄包 seed（同 iOS `SpeechEngine.cloudHints` 的排序）。
    /// 2026-10-20 iOS 實測：公平輪流把心肌梗塞、憲法、鋼筋混凝土排進前段，專名命中 22/39；這個順序 30/39。
    /// - Parameters:
    ///   - personal: 個人字典要的寫法（呼叫端已經照「輸出寫法空就用詞本身」處理、排好順序）。
    ///   - catalogSeeds: 已開 catalog 包的 seedTerms（照包的順序接起來）。
    ///   - script: 字形（`HanScript.personalHint`／`curatedHint`）：繁體只轉簡體寫的個人詞，內建包不轉；
    ///     簡體把有繁體專用字的詞轉簡體。轉完再去重。
    ///   - limit: 上限（各引擎自己的名額：Qwen／Groq 80、百鍊 50、Apple 語音 100）。
    ///   - toTraditional: 簡轉繁（Mac App 傳 OpenCC 按詞轉；預設 ICU）。
    public static func asrHints(personal: [String], enabled: Set<String>, catalogSeeds: [String],
                                script: HintScript, limit: Int,
                                excluding: Set<String> = asrHintExclusions,
                                toTraditional: (String) -> String = HanScript.icuTraditional,
                                toSimplified: (String) -> String = HanScript.icuSimplified) -> [String] {
        asrHints(personal: personal, packTerms: packsInHintOrder(enabled).flatMap(\.terms) + catalogSeeds,
                 script: script, limit: limit, excluding: excluding,
                 toTraditional: toTraditional, toSimplified: toSimplified)
    }

    /// 舊介面：`traditional` true＝`.traditional`、false＝`.asIs`。
    public static func asrHints(personal: [String], enabled: Set<String>, catalogSeeds: [String],
                                traditional: Bool, limit: Int,
                                excluding: Set<String> = asrHintExclusions) -> [String] {
        asrHints(personal: personal, enabled: enabled, catalogSeeds: catalogSeeds,
                 script: traditional ? .traditional : .asIs, limit: limit, excluding: excluding)
    }

    /// 排序與字形規則本體（Android core `AsrHints.hints` 同一條）：`packTerms`＝已照提示詞順序排好的內建包詞＋catalog 種子。
    public static func asrHints(personal: [String], packTerms: [String], script: HintScript, limit: Int,
                                excluding: Set<String> = asrHintExclusions,
                                toTraditional: (String) -> String = HanScript.icuTraditional,
                                toSimplified: (String) -> String = HanScript.icuSimplified) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        func add(_ term: String) -> Bool {
            guard !term.isEmpty, seen.insert(term).inserted else { return false }
            out.append(term)
            return out.count >= limit
        }
        for raw in personal {
            if add(HanScript.personalHint(raw, script: script, toTraditional: toTraditional, toSimplified: toSimplified)) {
                return out
            }
        }
        for raw in productNames {
            if add(raw) { return out }
        }
        for raw in packTerms where !excluding.contains(raw) {
            if add(HanScript.curatedHint(raw, script: script, toSimplified: toSimplified)) { return out }
        }
        return out
    }
}
