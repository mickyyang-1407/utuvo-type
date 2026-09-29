package com.utuvo.type

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader

/**
 * 詞庫目錄（2026-09-20 runtime 票，依 CONTRACT-V2.md 改 schema 2）：
 * app 啟動時只讀 metadata（catalog.json），terms 改成 `termsFile + termCount`；
 * 各包真實詞表（computing.txt 等）只在需要做明細搜尋／cleanup 相關度篩選時才延遲讀取。
 *
 * 與舊行為差別：
 * - metadata 與 terms 分檔，不再開機就把 40 萬詞全塞進記憶體；
 * - 各包 terms 預設為 null；只有 ensureLoadedTerms() 後才有；
 * - 從固定 id 推導檔名（`id + ".txt"`），禁止任意路徑讀檔；
 * - 失敗安全退回既有三包（ai/tw/audio 在 VocabularyPacks 內獨立處理）。
 */
object VocabularyCatalog {

    /** 來自 catalog.json metadata 的一包；`terms` 預設為 null（未載入）。 */
    data class Pack(
        val id: String,
        val name: String,
        val summary: String,
        val sourceName: String,
        val sourceURL: String,
        val licenseName: String,
        val licenseURL: String,
        val attribution: String,
        val version: String,
        val defaultOn: Boolean,
        val seedTerms: List<String>,
        val termCount: Int,
        val termsSHA256: String,
        /** 真實詞表（讀過 termsFile 後才有；未讀 = null）。 */
        var terms: List<String>? = null,
        val termsFile: String,
    )

    data class Catalog(val schemaVersion: Int, val packs: List<Pack>) {
        fun pack(id: String): Pack? = packs.firstOrNull { it.id == id }
        companion object {
            val empty = Catalog(0, emptyList())
            /** 固定六包 id（CONTRACT-V2 §1）。 */
            val knownIDs = listOf("computing", "medicine", "finance", "law", "engineering", "music")
        }
    }

    sealed class LoadError : Exception() {
        object Missing : LoadError()
        object Malformed : LoadError()
        data class Unsupported(val schema: Int) : LoadError()
    }

    /** 從 assets 讀 metadata。失敗回傳 Catalog.empty。 */
    fun load(c: Context, assetPath: String = "vocabulary/catalog.json"): Catalog {
        return try {
            val text = c.assets.open(assetPath).use { it.readBytes().toString(Charsets.UTF_8) }
            decode(text)
        } catch (_: Exception) {
            Catalog.empty
        }
    }

    /** 純 JSON 解析（測試與合成 fixture 共用）。 */
    fun decode(json: String): Catalog {
        val obj = try { JSONObject(json) } catch (_: Exception) { throw LoadError.Malformed }
        val schema = obj.optInt("schemaVersion", 0)
        if (schema != 2) throw LoadError.Unsupported(schema)
        val arr = obj.optJSONArray("packs") ?: throw LoadError.Malformed
        val out = mutableListOf<Pack>()
        for (i in 0 until arr.length()) {
            val raw = arr.optJSONObject(i) ?: continue
            val id = raw.optString("id").takeIf { it.isNotEmpty() } ?: continue
            val name = raw.optString("name").takeIf { it.isNotEmpty() } ?: continue
            val summary = raw.optString("summary")
            val sourceName = raw.optString("sourceName")
            val sourceURL = raw.optString("sourceURL")
            val licenseName = raw.optString("licenseName")
            val licenseURL = raw.optString("licenseURL")
            val attribution = raw.optString("attribution")
            val version = raw.optString("version")
            val defaultOn = raw.optBoolean("defaultOn", false)
            val seedTerms = raw.optJSONArray("seedTerms").toStringList()
            val termCount = raw.optInt("termCount", 0)
            val termsSHA256 = raw.optString("termsSHA256")
            val termsFile = raw.optString("termsFile")
            out.add(Pack(id, name, summary, sourceName, sourceURL, licenseName, licenseURL,
                attribution, version, defaultOn, seedTerms, termCount, termsSHA256, null, termsFile))
        }
        return Catalog(schema, out)
    }

    private fun JSONArray?.toStringList(): List<String> {
        if (this == null) return emptyList()
        val out = ArrayList<String>(length())
        for (i in 0 until length()) out.add(optString(i, ""))
        return out.filter { it.isNotEmpty() }
    }
}

// MARK: - 延遲詞表載入（按需讀 .txt）

interface PackTermsSource {
    /** 讀 `id + ".txt"`；id 不在白名單或檔案不存在，回 null。 */
    fun readTermsFile(packID: String): List<String>?
}

/** 預設從 Android assets `vocabulary/{id}.txt` 讀。 */
class AssetPackTermsSource(private val assets: android.content.res.AssetManager) : PackTermsSource {
    private val cache = HashMap<String, List<String>>()

    override fun readTermsFile(packID: String): List<String>? {
        cache[packID]?.let { return it }
        if (!isAllowedID(packID)) return null
        val path = "vocabulary/$packID.txt"
        val out = try {
            assets.open(path).use { stream ->
                BufferedReader(stream.reader(Charsets.UTF_8)).useLines { lines ->
                    val list = ArrayList<String>(2048)
                    var count = 0
                    lines.forEach { raw ->
                        val t = raw.trim()
                        if (isCleanTerm(t)) {
                            list.add(t)
                            count++
                        }
                    }
                    list
                }
            }
        } catch (_: Exception) {
            null
        }
        cache[packID] = out ?: emptyList()
        return out
    }

    companion object {
        fun isAllowedID(id: String): Boolean = VocabularyCatalog.Catalog.knownIDs.contains(id)

        /** 與 data writer 同樣的清洗：去 HTML／公式／控制字元／數字編號片段。
         *  `&` 是合法詞（AT&T世界網／H&E染色法／程式&時鐘板，Kimi review round 1）：
         *  curated txt 不做 HTML decoding，直接收；`<`／`>`／`\t` 仍拒。 */
        fun isCleanTerm(t: String): Boolean {
            if (t.length !in 2..40) return false
            if (t.contains('<') || t.contains('>') || t.contains('\t')) return false
            var open = 0
            for (c in t) {
                if (c == '(') open++ else if (c == ')') open--
                if (open < 0 || open > 1) return false
            }
            return open == 0
        }
    }
}

/**
 * 選詞（純函式，可獨立測試）。
 *
 * 給智慧整理的專有名詞：個人字典優先（output 空字串時詞本身有效），
 * 再從所有已開啟專業包依 bigram／latin token 相關度篩入，未匹配時各包 seedTerms 公平輪流補滿。
 */
object VocabularySelector {
    const val CLEANUP_TOKEN_LIMIT = 200
    const val SEED_FALLBACK_PER_PACK = 6
    private const val SEARCH_LIMIT = 100
    private const val CANDIDATES_PER_PACK = 30

    fun termsForCleanup(
        text: String?,
        enabled: List<VocabularyCatalog.Pack>,
        personal: Map<String, String>,
        stations: Set<String>,
        limit: Int = CLEANUP_TOKEN_LIMIT,
    ): List<String> {
        // 個人字典：output 空字串時詞本身也有效。
        val seen = HashSet<String>()
        val personalTerms = personal.flatMap { (k, v) ->
            if (v.isEmpty()) listOf(k) else listOf(v, k)
        }.filter { it.isNotEmpty() }
        val out = ArrayList<String>(limit)
        for (t in personalTerms) {
            if (seen.add(t)) out.add(t)
            if (out.size >= limit) return out.take(limit)
        }
        // 從專業包依相關度篩入（公平合併，避免單一大包擠掉其他包）。
        for (t in collectCandidates(text, enabled, stations)) {
            if (seen.add(t)) out.add(t)
            if (out.size >= limit) return out.take(limit)
        }
        // 未匹配：seedTerms 公平輪流。
        for (t in fairSeedRotation(enabled, stations)) {
            if (seen.add(t)) out.add(t)
            if (out.size >= limit) return out.take(limit)
        }
        return out.take(limit)
    }

    fun collectCandidates(
        text: String?,
        enabled: List<VocabularyCatalog.Pack>,
        stations: Set<String>,
    ): List<String> {
        if (text.isNullOrEmpty()) return emptyList()
        val overlap = BigramOverlap.bigramsUInt64(text)
        val latin = LatinTokens.tokens(text)
        if (overlap.isEmpty() && latin.isEmpty()) return emptyList()
        val needsStations = text.contains("站") || text.contains("捷運")
        val checkCJK = overlap.isNotEmpty()
        val checkLatin = latin.isNotEmpty()
        val perPack = ArrayList<List<String>>(enabled.size)
        for (pack in enabled) {
            val terms = pack.terms ?: continue
            val scored = ArrayList<Pair<String, Int>>(minOf(terms.size, 200))
            for (t in terms) {
                if (t.isEmpty()) continue
                if (!needsStations && t in stations) continue
                val s = TermScanner.score(t, overlap, latin, checkCJK, checkLatin, text)
                if (s > 0) scored.add(t to s)
            }
            scored.sortWith(compareByDescending<Pair<String, Int>> { it.second }
                .thenBy { it.first.length }
                .thenBy { it.first })
            perPack.add(scored.take(CANDIDATES_PER_PACK).map { it.first })
        }
        return fairMerge(perPack)
    }

    /** 公平合併：每包輪流抽一個。終止條件是「仍有未消耗元素」（RUNTIME-FINDINGS #4）。 */
    private fun fairMerge(perPack: List<List<String>>): List<String> {
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        val cursors = IntArray(perPack.size)
        while (true) {
            var progressed = false
            for (i in perPack.indices) {
                val arr = perPack[i]
                if (cursors[i] >= arr.size) continue
                val t = arr[cursors[i]]
                cursors[i]++
                progressed = true
                if (seen.add(t)) out.add(t)
            }
            if (!progressed) break
        }
        return out
    }

    /** seed 公平輪流：終止條件同上（RUNTIME-FINDINGS #4）。 */
    fun fairSeedRotation(
        enabled: List<VocabularyCatalog.Pack>,
        stations: Set<String>,
    ): List<String> {
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        val cursors = IntArray(enabled.size)
        val hardCap = minOf(enabled.maxOfOrNull { it.seedTerms.size } ?: 0, 80)
        while (true) {
            var progressed = false
            for (i in enabled.indices) {
                val sList = enabled[i].seedTerms
                if (cursors[i] >= sList.size) continue
                val s = sList[cursors[i]]
                cursors[i]++
                progressed = true
                if (s in stations) continue
                if (seen.add(s)) out.add(s)
            }
            if (!progressed) break
            if (cursors.all { it >= hardCap }) break
        }
        return out
    }

    fun latinSeedTerms(enabled: List<VocabularyCatalog.Pack>): List<String> {
        val seen = HashSet<String>()
        val out = ArrayList<String>()
        for (pack in enabled) {
            for (s in pack.seedTerms) {
                if (s.any { it.code < 128 && it.isLetter() } && seen.add(s)) out.add(s)
            }
        }
        return out
    }

    /** 給搜尋 UI：seed 優先，已載入的 terms 再比；結果上限 100。 */
    fun search(query: String, pack: VocabularyCatalog.Pack, limit: Int = SEARCH_LIMIT): List<String> {
        val q = query.trim()
        if (q.isEmpty()) return emptyList()
        val out = ArrayList<String>(limit)
        val seen = HashSet<String>()
        for (t in pack.seedTerms) {
            if (t.contains(q) && seen.add(t)) { out.add(t); if (out.size >= limit) return out }
        }
        pack.terms?.let { terms ->
            for (t in terms) {
                if (t.contains(q) && seen.add(t)) { out.add(t); if (out.size >= limit) return out }
            }
        }
        return out
    }

    private fun score(term: String, bigrams: Set<String>, latin: Set<String>, text: String): Int {
        // 不再被 collectCandidates 直接呼叫；保留以相容舊 callers。
        return TermScanner.score(term, BigramOverlap.bigramsUInt64(term), latin, bigrams.isNotEmpty(), latin.isNotEmpty(), text)
    }
}

/**
 * 共享單詞掃描器（RUNTIME-PERF 熱迴圈版）：
 * - bigram 用 Long packed（CJK codepoint1<<32 | codepoint2），避免每詞建 String Set；
 * - 一次 unicode 掃描同時撈 bigram overlap + 標記 CJK／latin。
 */
object TermScanner {
    fun score(
        term: String,
        overlap: Set<Long>,
        latin: Set<String>,
        checkCJK: Boolean,
        checkLatin: Boolean,
        text: String,
    ): Int {
        var s = 0
        var hasCJK = false
        var hasLatin = false
        var lastCJK: Int? = null
        for (c in term) {
            val v = c.code
            if (v in 0x3400..0x9FFF) {
                hasCJK = true
                if (checkCJK && lastCJK != null) {
                    val key = (lastCJK.toLong() shl 32) or v.toLong()
                    if (overlap.contains(key)) s += 2
                }
                lastCJK = v
            } else {
                lastCJK = null
                if (v < 128 && (c in 'A'..'Z' || c in 'a'..'z')) {
                    hasLatin = true
                }
            }
        }
        if (hasCJK && !hasLatin && !checkCJK) return 0
        if (hasLatin && !hasCJK && !checkLatin) return 0
        if (hasLatin) {
            val termTokens = LatinTokens.tokens(term)
            s += (termTokens intersect latin).size
        }
        if (text.contains(term)) s += 10
        return s
    }
}

/** 簡單中文 bigram（不做斷詞；CJK 兩兩相連）。 */
object BigramOverlap {
    fun bigrams(text: String): Set<String> {
        val out = HashSet<String>()
        var i = 0
        while (i < text.length - 1) {
            val a = text[i]; val b = text[i + 1]
            if (isCJK(a) && isCJK(b)) out.add("$a$b")
            i++
        }
        return out
    }
    /** RUNTIME-PERF 熱迴圈版：CJK codepoint packed Long，HashSet<Long> 比 HashSet<String> 便宜。 */
    fun bigramsUInt64(text: String): Set<Long> {
        val out = HashSet<Long>()
        var last: Int? = null
        for (c in text) {
            val v = c.code
            if (v in 0x3400..0x9FFF) {
                if (last != null) {
                    val key = (last.toLong() shl 32) or v.toLong()
                    out.add(key)
                }
                last = v
            } else {
                last = null
            }
        }
        return out
    }
    fun hasCJK(text: String): Boolean {
        for (c in text) if (isCJK(c)) return true
        return false
    }
    fun isCJK(c: Char): Boolean {
        val v = c.code
        return v in 0x3400..0x9FFF
    }
}

/** 拉丁字母 token 切分（空白／標點）。 */
object LatinTokens {
    fun tokens(text: String): Set<String> {
        val out = HashSet<String>()
        val sb = StringBuilder()
        fun flush() {
            val t = sb.toString().lowercase()
            if (t.length >= 2) out.add(t)
            sb.setLength(0)
        }
        for (c in text) {
            val isLatin = c.code < 128 && (c.isLetterOrDigit())
            if (isLatin) sb.append(c) else flush()
        }
        flush()
        return out
    }
    fun hasLatin(text: String): Boolean {
        for (c in text) if (c.code < 128 && c.isLetterOrDigit()) return true
        return false
    }
}