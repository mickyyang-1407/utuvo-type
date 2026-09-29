package com.utuvo.type

import android.content.Context

/**
 * 詞庫包（同 iOS VocabularyPacks；2026-09-20 Micky：「像百度、搜狗那樣有專門字典可以加」；
 * 實測 Gemini→Jamin、ChatGPT→Chit GPT、Claude Code→cloudcoate）。
 *
 * 2026-09-20 runtime 票（CONTRACT-V2）：
 * - 內建三包（ai／tw／audio）保留；
 * - 新增六個 catalog 詞庫（資訊／醫療／財經／法律／工程／音樂音訊），預設全關；
 * - catalog 來源：`assets/vocabulary/catalog.json` + `vocabulary/{id}.txt`；
 * - 啟動時只讀 metadata，terms 透過 PackTermsSource 依使用情境延遲載入。
 */
object VocabularyPacks {
    /** seedCount：併入 selector 時當 seedTerms 的詞數（站名先排除；站名只在提到站／捷運時經相關度帶入）。 */
    data class Pack(val id: String, val nameRes: Int, val summary: String, val terms: List<String>, val defaultOn: Boolean,
                    val seedCount: Int = 8)

    /** 台北捷運站名（不含「站」；與 iOS TaiwanPlaces.taipeiMRT 同一份）。 */
    val taipeiMRT = listOf(
        "淡水", "紅樹林", "竹圍", "關渡", "忠義", "復興崗", "北投", "新北投", "奇岩", "唭哩岸", "石牌", "明德", "芝山", "士林", "劍潭", "圓山", "民權西路",
        "雙連", "中山", "台北車站", "台大醫院", "中正紀念堂", "東門", "大安森林公園", "大安", "信義安和", "台北101", "世貿", "象山", "松山", "南京三民", "台北小巨蛋",
        "南京復興", "松江南京", "北門", "西門", "小南門", "古亭", "台電大樓", "公館", "萬隆", "景美", "大坪林", "七張", "新店區公所", "新店", "小碧潭", "頂埔",
        "永寧", "土城", "海山", "亞東醫院", "府中", "板橋", "新埔", "江子翠", "龍山寺", "善導寺", "忠孝新生", "忠孝復興", "忠孝敦化", "國父紀念館", "市政府", "永春",
        "後山埤", "昆陽", "南港", "南港展覽館", "南勢角", "景安", "永安市場", "頂溪", "行天宮", "中山國小", "民權西路", "大橋頭", "台北橋", "菜寮", "三重", "先嗇宮",
        "頭前庄", "新莊", "輔大", "丹鳳", "迴龍", "三重國小", "三和國中", "徐匯中學", "三民高中", "蘆洲", "動物園", "木柵", "萬芳社區", "萬芳醫院", "辛亥", "麟光",
        "六張犁", "科技大樓", "中山國中", "松山機場", "大直", "劍南路", "西湖", "港墘", "文德", "內湖", "大湖公園", "葫洲", "東湖", "南港軟體園區", "十四張", "秀朗橋",
        "景平", "中和", "橋和", "中原", "板新", "新埔民生", "幸福", "新北產業園區"
    )

    val all = listOf(
        Pack("ai", R.string.pack_ai, "Gemini、ChatGPT、Claude、Perplexity…", listOf(
            "Gemini", "Google Gemini", "ChatGPT", "OpenAI", "GPT", "Claude", "Claude Code", "Anthropic", "Perplexity",
            // 2026-09-20 實機：公司名講出來會變成 AppleNVidia／MiniMax／GLMKimi，詞庫沒有就救不回來
            "Apple", "Google", "Microsoft", "Amazon", "Meta", "Tesla", "Samsung", "Intel", "AMD", "Sora",
            "MiniMax", "GLM", "Zhipu", "Moonshot", "Doubao", "Hunyuan", "Mistral", "Cohere", "Whisper",
            "Ollama", "Hugging Face", "Vercel", "Cloudflare", "Supabase", "Xcode", "Kotlin", "SwiftUI",
            "session", "token", "LLM", "MCP", "SDK", "CLI", "repo", "commit",
            "Copilot", "GitHub", "Cursor", "Codex", "Midjourney", "Stable Diffusion", "DeepSeek", "Qwen", "Llama",
            "Grok", "Kimi", "Typeless", "Chatterfly", "Notion", "Figma", "Canva", "Slack", "Discord", "Telegram",
            "LINE", "Threads", "Instagram", "Facebook", "YouTube", "TikTok", "iPhone", "iPad", "MacBook",
            "Apple Intelligence", "Siri", "Android", "Pixel", "NVIDIA", "TSMC", "API", "Prompt", "Vibe Coding"), true),
        Pack("tw", R.string.pack_tw, "捷運站名、西門町、南崁…", taipeiMRT.distinct().map { it + "站" } + listOf(
            "西門町", "南崁", "蘆洲", "板橋", "信義區", "台北車站", "桃園機場", "高鐵",
            "台鐵", "捷運", "悠遊卡", "一卡通", "捷安特", "全聯", "家樂福", "7-Eleven", "全家"), true,
            // 站名以外全帶（catalog 前的行為）；前 8 詞原本全是站名，被站名過濾後整包歸零
            seedCount = Int.MAX_VALUE),
        Pack("audio", R.string.pack_audio, "Atmos、Pro Tools、stem、LUFS…", listOf(
            "Dolby Atmos", "Atmos", "Pro Tools", "Logic Pro", "Ableton", "Cubase", "Nuendo", "DaVinci Resolve",
            "ADM", "BWF", "binaural", "stem", "stems", "LUFS", "True Peak", "bed", "object", "renderer",
            "mixing", "mastering", "混音", "母帶", "分軌", "錄音室", "Tonmeister", "Apple Music", "Spotify"), false),
    )

    private const val PREF = "vocabularyPacks"
    private const val FIELD = "enabled"

    private fun prefs(c: Context) = c.getSharedPreferences(PREF, Context.MODE_PRIVATE)

    // MARK: - catalog（測試可注入）

    @Volatile private var cachedCatalog: VocabularyCatalog.Catalog = VocabularyCatalog.Catalog.empty
    @Volatile private var termsSource: PackTermsSource? = null  // null = 走 AssetPackTermsSource

    /** 對外暴露已快取的 catalog；只含 metadata。 */
    @JvmStatic fun catalog(): VocabularyCatalog.Catalog = cachedCatalog

    /** 注入測試 seam：合成 pack terms（id -> terms）。 */
    @JvmStatic fun setCatalogForTest(c: VocabularyCatalog.Catalog) { cachedCatalog = c }
    @JvmStatic fun setTermsSourceForTest(s: PackTermsSource) { termsSource = s }

    /** 解析並快取 catalog；失敗時維持空。 */
    @JvmStatic fun loadCatalog(c: Context) {
        cachedCatalog = VocabularyCatalog.load(c)
    }

    /**
     * pipeline 入口用（RUNTIME-INTEGRATION-FINDINGS #1）：語音辨識／智慧整理不會經過設定頁，
     * cachedCatalog 還是空時在這裡載一次 metadata。@Volatile + 呼叫端皆在主執行緒，雙讀最壞只是重解析一次。
     */
    @JvmStatic fun ensureCatalogLoaded(c: Context) {
        if (cachedCatalog.schemaVersion != VocabularyCatalog.Catalog.empty.schemaVersion) return
        loadCatalog(c)
    }

    private fun source(c: Context): PackTermsSource =
        termsSource ?: AssetPackTermsSource(c.assets).also { termsSource = it }

    /** 已開啟的 catalog 詞庫包 metadata。 */
    @JvmStatic fun enabledCatalogPacks(c: Context): List<VocabularyCatalog.Pack> {
        ensureCatalogLoaded(c)
        return cachedCatalog.packs.filter { isCatalogPackEnabled(c, it) }
    }

    /** 已開啟 + 確保 terms 已載入（cleanup pipeline 進入時呼叫一次，後續共享快取）。 */
    @JvmStatic fun enabledCatalogPacksLoaded(c: Context): List<VocabularyCatalog.Pack> {
        val src = source(c)
        return enabledCatalogPacks(c).map { pack ->
            if (pack.terms == null) {
                pack.terms = src.readTermsFile(pack.id)
                pack
            } else pack
        }
    }

    /** 明細頁搜尋用：不管開／關都把【這一包】的完整詞表載入（只載指定的包，不動其他包、不隱式啟用）。 */
    @JvmStatic fun packWithTermsLoaded(c: Context, id: String): VocabularyCatalog.Pack? {
        ensureCatalogLoaded(c)
        val pack = cachedCatalog.packs.firstOrNull { it.id == id } ?: return null
        if (pack.terms != null) return pack
        pack.terms = source(c).readTermsFile(pack.id)
        return pack
    }

    private fun isCatalogPackEnabled(c: Context, pack: VocabularyCatalog.Pack): Boolean {
        val stored = prefs(c).getStringSet(FIELD, null) ?: return pack.defaultOn
        return pack.id in stored
    }

    @JvmStatic fun isEnabled(c: Context, pack: Pack): Boolean {
        val stored = prefs(c).getStringSet(FIELD, null) ?: return pack.defaultOn
        return pack.id in stored
    }

    @JvmStatic fun setEnabled(c: Context, pack: Pack, on: Boolean) {
        mutateEnabled(c) { ids ->
            if (on) ids += pack.id else ids -= pack.id
        }
    }

    @JvmStatic fun setCatalogEnabled(c: Context, pack: VocabularyCatalog.Pack, on: Boolean) {
        mutateEnabled(c) { ids ->
            if (on) ids += pack.id else ids -= pack.id
        }
    }

    /** 同時管內建三包與 catalog 六包（同一份 enabledKey）。 */
    private fun mutateEnabled(c: Context, change: (MutableSet<String>) -> Unit) {
        val ids = HashSet<String>()
        all.filter { isEnabled(c, it) }.mapTo(ids) { it.id }
        enabledCatalogPacks(c).mapTo(ids) { it.id }
        change(ids)
        prefs(c).edit().putStringSet(FIELD, ids).apply()
    }

    /** 內建詞庫已開詞（去重）。 */
    @JvmStatic fun enabledTerms(c: Context): List<String> = all.filter { isEnabled(c, it) }.flatMap { it.terms }.distinct()

    /**
     * 給智慧整理的專有名詞：個人字典優先（output 空字串時詞本身也有效），
     * 再從已開啟專業包依 bigram／latin token 相關度篩入，未匹配時各包 seedTerms 公平輪流補滿。
     * 捷運站名只在提到「站／捷運」時帶。
     * 上限 200。真正觸發 lazy 載入（已開啟包的 terms 一次讀完，後續 pipeline 共享快取）。
     *
     * RUNTIME-FINDINGS #5：內建三包每個都當獨立 pseudo pack，terms = 該包完整詞，
     * seedTerms = 該包站名以外前 seedCount 個代表詞，避免 ai+tw 預設全展開塞光 cleanup 提示詞。
     */
    @JvmStatic fun termsForCleanup(c: Context, text: String? = null, dictionary: Map<String, String> = DictionaryStore.entries(c)): List<String> {
        val stations = taipeiMRT.map { it + "站" }.toSet()
        val enabled = enabledCatalogPacksLoaded(c)
        val pseudo = pseudoPacks(c, stations)
        return VocabularySelector.termsForCleanup(text, enabled + pseudo, dictionary, stations)
    }

    /**
     * 給辨識器的提示詞（個人字典優先，再補已開啟詞庫，上限 200）。
     * RUNTIME-FINDINGS #2：不要先 append enabledTerms（ai+tw 預設就 >200），
     * 改為【內建三包 terms + 六新包 seed】公平輪流。
     */
    @JvmStatic fun biasing(c: Context): ArrayList<String> {
        val out = ArrayList<String>(200)
        val seen = HashSet<String>()
        // 個人字典優先（Kimi review round 1：原 dead loop 只送 DictionaryStore.biasing 的 values，
        // vocabulary-only 條目（output 空）的 source 詞不會進提示詞，與 iOS contextualHints 不一致）：
        // output 非空用 output（不送 source 錯誤拼字）、output 空送 source 本身；濾空、去重、上限 200。
        for ((k, v) in DictionaryStore.entries(c)) {
            val term = if (v.isNotEmpty()) v else k
            if (term.isNotEmpty() && seen.add(term)) out.add(term)
            if (out.size >= 200) return out
        }
        // 公平輪流：已開啟的內建三包全部 terms + 已開啟 catalog 六包 seedTerms。
        // RUNTIME-INTEGRATION-FINDINGS #2：all.map 改 filter { isEnabled }——關掉的包不得出聲。
        val streams: List<List<String>> =
            all.filter { isEnabled(c, it) }.map { it.terms } + enabledCatalogPacks(c).map { it.seedTerms }
        val cursors = IntArray(streams.size)
        while (out.size < 200) {
            var progressed = false
            for (i in streams.indices) {
                if (cursors[i] >= streams[i].size) continue
                val t = streams[i][cursors[i]]
                cursors[i]++
                progressed = true
                if (seen.add(t)) {
                    out.add(t)
                    if (out.size >= 200) return out
                }
            }
            if (!progressed) break
        }
        return out
    }

    /**
     * 給英文專名修正（LatinNameFixer）的比對目標：個人字典＋內建三包＋catalog 各包 seedTerms。
     * **不**載入 catalog 包的 terms（避免幾萬詞灌進 fuzzy 比對）。
     */
    @JvmStatic fun latinTermsForFixer(c: Context, dictionary: Map<String, String> = DictionaryStore.entries(c)): List<String> {
        val catalogSeeds = VocabularySelector.latinSeedTerms(enabledCatalogPacks(c))
        return (dictionary.values + enabledTerms(c) + catalogSeeds)
            .filter { t -> t.any { it.code < 128 && it.isLetter() } }
            .distinct()
    }

    /** RUNTIME-INTEGRATION-FINDINGS #2：只用「已開啟」的內建包；關掉的 audio 不得進 cleanup 提示詞。 */
    private fun pseudoPacks(c: Context, stations: Set<String>): List<VocabularyCatalog.Pack> = all.filter { isEnabled(c, it) }.map { builtIn ->
        VocabularyCatalog.Pack(
            id = "__builtin_${builtIn.id}",
            name = builtIn.id,
            summary = builtIn.summary,
            sourceName = "UTUVO Type", sourceURL = "",
            licenseName = "", licenseURL = "",
            attribution = "2026-09-20 整理", version = "builtin",
            defaultOn = builtIn.defaultOn,
            seedTerms = builtIn.terms.asSequence().filter { it !in stations }.take(builtIn.seedCount).toList(),
            termCount = builtIn.terms.size,
            termsSHA256 = "",
            terms = builtIn.terms,
            termsFile = ""
        )
    }

    // MARK: - 六個 catalog id 的顯示名稱／摘要（在地化）

    /** catalog.json 的 name／summary 只有繁中；六個固定 id 走在地化字串資源，未知 id 退回 JSON 原文。
     *  來源授權（sourceName/licenseName/attribution）保持原文不翻。 */
    @JvmStatic fun catalogDisplayName(c: Context, id: String, fallback: String): String {
        val res = when (id) {
            "computing" -> R.string.pack_computing_name
            "medicine" -> R.string.pack_medicine_name
            "finance" -> R.string.pack_finance_name
            "law" -> R.string.pack_law_name
            "engineering" -> R.string.pack_engineering_name
            "music" -> R.string.pack_music_name
            else -> return fallback
        }
        return c.getString(res)
    }

    @JvmStatic fun catalogDisplaySummary(c: Context, id: String, fallback: String): String {
        val res = when (id) {
            "computing" -> R.string.pack_computing_summary
            "medicine" -> R.string.pack_medicine_summary
            "finance" -> R.string.pack_finance_summary
            "law" -> R.string.pack_law_summary
            "engineering" -> R.string.pack_engineering_summary
            "music" -> R.string.pack_music_summary
            else -> return fallback
        }
        return c.getString(res)
    }

    /** 匯入：一行一個詞，或「聽到→改成」（也接受 -> 、=>、Tab）。回傳加了幾筆。 */
    @JvmStatic fun importLines(c: Context, text: String): Int {
        var added = 0
        for (raw in text.lines()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            val sep = listOf("→", "->", "=>", "\t").firstOrNull { line.contains(it) }
            if (sep != null) {
                val parts = line.split(sep).map { it.trim() }
                if (parts.size < 2 || parts[0].isEmpty() || parts[1].isEmpty()) continue
                DictionaryStore.add(c, parts[0], parts[1])
            } else {
                if (line.length > 40) continue
                DictionaryStore.add(c, line, "")
            }
            added++
        }
        return added
    }
}