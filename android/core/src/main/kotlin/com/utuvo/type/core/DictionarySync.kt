package com.utuvo.type.core

import org.json.JSONObject

/**
 * 個人字典跨裝置同步（同 Swift `DictionarySync`）：每筆記最後改動時間、刪除留墓碑（output = null），
 * 合併時同一個詞「最後改的贏」。匯出檔格式三平台互通。
 */
data class DictionarySync(val entries: Map<String, Entry> = emptyMap()) {
    /** 詞是使用者自己打上去的，還是鍵盤聽寫後學到的（決定字典頁分頁與能不能一鍵忽略）。 */
    enum class Source { MANUAL, AUTO;
        companion object {
            /** 舊檔案沒有這個欄位 → 算手動（使用者自己加的）。 */
            fun parse(raw: String?) = if (raw == AUTO.name) AUTO else MANUAL
        }
    }

    /** at：秒（Unix epoch）；output null＝已刪除；source 舊檔會缺（當手動）。 */
    data class Entry(val output: String?, val at: Double, val source: Source = Source.MANUAL)

    companion object {
        const val FORMAT = "utuvo-type-dictionary"
        const val VERSION = 1
        const val TOMBSTONE_LIFETIME = 180.0 * 24 * 3600

        fun fromPlain(plain: Map<String, String>, at: Double = 0.0) = DictionarySync(plain.mapValues { Entry(it.value, at) })

        /**
         * 全序比較（同 Swift `DictionarySync.wins`）：時間 → 有值 → 寫法字典序 → 來源（手動 > 自動）。
         * 來源那一層（2026-10-22 修補）：舊版用戶端不認得 source，把 AUTO 讀成手動再寫回；兩份只差來源時
         * 沒有這層 a.merged(b) ≠ b.merged(a)，兩台會互相覆寫。手動贏＝使用者的詞不會被降成自動。
         */
        internal fun wins(a: Entry, b: Entry): Boolean {
            if (a.at != b.at) return a.at > b.at
            return when {
                a.output != null && b.output == null -> true
                a.output == null && b.output != null -> false
                a.output != null && b.output != null && a.output != b.output -> a.output > b.output
                else -> a.source == Source.MANUAL && b.source == Source.AUTO
            }
        }

        class NotDictionaryFile : Exception("not a UTUVO Type dictionary file")
        class NewerVersion(val version: Int) : Exception("dictionary file version $version is newer")

        /** 讀匯出檔；也接受舊的純 `{聽到: 改成}` JSON（時間當 0）。 */
        fun decode(text: String): DictionarySync {
            val o = runCatching { JSONObject(text) }.getOrElse { throw NotDictionaryFile() }
            if (o.has("format") || o.has("entries")) {
                if (o.optString("format") != FORMAT) throw NotDictionaryFile()
                val v = o.optInt("version", 0)
                if (v > VERSION) throw NewerVersion(v)
                val e = o.optJSONObject("entries") ?: throw NotDictionaryFile()
                return DictionarySync(e.keys().asSequence().associateWith { k ->
                    val x = e.getJSONObject(k)
                    Entry(
                        if (x.has("output") && !x.isNull("output")) x.getString("output") else null,
                        x.getDouble("at"),
                        Source.parse(x.optString("source")),
                    )
                })
            }
            val plain = o.keys().asSequence().associateWith { k -> o.opt(k) as? String ?: throw NotDictionaryFile() }
            return fromPlain(plain)
        }

        // 純詞表匯入（2026-10-22 app-shell-6；同 Swift `DictionarySync`，同一份測試樣本）

        /** 詞表檔大小上限（對齊 Typeless 的 5 MB）。 */
        const val MAX_WORD_LIST_BYTES = 5 * 1024 * 1024

        class WordListTooLarge : Exception("word list is larger than 5 MB")
        class NoWords : Exception("no words found")

        /**
         * 內容看起來像 JSON：去掉 BOM 和空白後第一個字是 `{` 或 `[`。看起來像 JSON 的一律走 [decode]，
         * 壞掉的匯出檔才不會被當成詞表。
         */
        fun looksLikeJson(text: String): Boolean {
            val first = text.firstOrNull { it != '\uFEFF' && !it.isWhitespace() }
            return first == '{' || first == '['
        }

        /**
         * 一行一詞的詞表（.txt、一欄 CSV）：去 BOM、接受 CRLF／CR；每行取第一欄（CSV 雙引號照規則解，`""` 是一個 `"`），
         * 去前後空白、略過空行、重複的只留第一個。超過 5 MB 丟 [WordListTooLarge]，一個詞都沒有丟 [NoWords]。
         */
        fun parseWordList(text: String): List<String> {
            if (text.toByteArray(Charsets.UTF_8).size > MAX_WORD_LIST_BYTES) throw WordListTooLarge()
            val body = text.removePrefix("\uFEFF").replace("\r\n", "\n").replace('\r', '\n')
            val words = LinkedHashSet<String>()
            for (line in body.split('\n')) {
                val word = firstCsvColumn(line)
                if (word.isNotEmpty()) words.add(word)
            }
            if (words.isEmpty()) throw NoWords()
            return words.toList()
        }

        internal fun firstCsvColumn(line: String): String {
            val s = line.trim()
            if (!s.startsWith('"')) {
                val end = s.indexOf(',').let { if (it < 0) s.length else it }
                return s.substring(0, end).trim()
            }
            val out = StringBuilder()
            var i = 1
            while (i < s.length) {
                if (s[i] == '"') {
                    if (i + 1 < s.length && s[i + 1] == '"') { out.append('"'); i += 2; continue }
                    break
                }
                out.append(s[i]); i++
            }
            return out.toString().trim()
        }
    }

    /** 目前有效的字典。 */
    val live: Map<String, String> get() = entries.mapNotNull { (k, v) -> v.output?.let { k to it } }.toMap()

    fun set(source: String, output: String, at: Double, origin: Source = Source.MANUAL): DictionarySync {
        val s = source.trim()
        if (s.isEmpty()) return this
        val o = output.trim()
        val out = o.ifEmpty { s }
        val prev = entries[s]
        // 2026-10-13 修補：來源判斷原本寫反了——手動的詞被自動學到時會變成 AUTO。
        // 規則：使用者手動加入一律手動；已存在的詞維持原來源；新詞（或刪掉後重新學到）才標自動。
        val mark = when {
            origin == Source.MANUAL -> Source.MANUAL
            prev == null || prev.output == null -> Source.AUTO
            else -> prev.source
        }
        return DictionarySync(entries + (s to Entry(out, at, mark)))
    }

    /** 詞表裡哪些詞是新的（字典裡沒有、或之前刪掉的）。已經有的詞不動：使用者設定的輸出寫法不能被匯入蓋掉。 */
    fun newWords(words: List<String>): List<String> {
        val seen = HashSet<String>()
        return words.mapNotNull { raw ->
            val w = raw.trim()
            if (w.isEmpty() || entries[w]?.output != null || !seen.add(w)) null else w
        }
    }

    /** 把詞表加進字典：只加新的詞，寫法＝詞本身、時間 at、來源手動。 */
    fun addingWords(words: List<String>, at: Double): DictionarySync =
        newWords(words).fold(this) { d, w -> d.set(w, w, at, Source.MANUAL) }

    fun remove(source: String, at: Double): DictionarySync =
        if (source !in entries) this else DictionarySync(entries + (source to Entry(null, at)))

    /** 本機 `{聽到: 改成}` 被直接改過：多的＝新增、少的＝刪除、值不同＝修改，都記成 at。 */
    fun reconcile(plain: Map<String, String>, at: Double): DictionarySync {
        val out = entries.toMutableMap()
        for ((s, o) in plain) if (out[s]?.output != o) out[s] = Entry(o, at)
        for ((s, e) in entries) if (e.output != null && s !in plain) out[s] = Entry(null, at)
        return DictionarySync(out)
    }

    fun merged(other: DictionarySync): DictionarySync {
        val out = entries.toMutableMap()
        for ((s, theirs) in other.entries) {
            val mine = out[s]
            if (mine == null || wins(theirs, mine)) out[s] = theirs
        }
        return DictionarySync(out)
    }

    fun pruned(now: Double) = DictionarySync(entries.filter { it.value.output != null || now - it.value.at < TOMBSTONE_LIFETIME })

    fun encode(): String {
        val e = JSONObject()
        for ((k, v) in entries.toSortedMap()) e.put(k, JSONObject().put("at", v.at).apply {
            v.output?.let { put("output", it) }
            put("source", v.source.name)
        })
        return JSONObject().put("format", FORMAT).put("version", VERSION).put("entries", e).toString(2)
    }
}
