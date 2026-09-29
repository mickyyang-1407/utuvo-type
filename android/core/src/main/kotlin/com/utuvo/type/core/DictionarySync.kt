package com.utuvo.type.core

import org.json.JSONObject

/**
 * 個人字典跨裝置同步（同 Swift `DictionarySync`）：每筆記最後改動時間、刪除留墓碑（output = null），
 * 合併時同一個詞「最後改的贏」。匯出檔格式三平台互通。
 */
data class DictionarySync(val entries: Map<String, Entry> = emptyMap()) {
    /** at：秒（Unix epoch）；output null＝已刪除。 */
    data class Entry(val output: String?, val at: Double)

    companion object {
        const val FORMAT = "utuvo-type-dictionary"
        const val VERSION = 1
        const val TOMBSTONE_LIFETIME = 180.0 * 24 * 3600

        fun fromPlain(plain: Map<String, String>, at: Double = 0.0) = DictionarySync(plain.mapValues { Entry(it.value, at) })

        internal fun wins(a: Entry, b: Entry): Boolean {
            if (a.at != b.at) return a.at > b.at
            return when {
                a.output == null -> false
                b.output == null -> true
                else -> a.output > b.output
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
                    Entry(if (x.has("output") && !x.isNull("output")) x.getString("output") else null, x.getDouble("at"))
                })
            }
            val plain = o.keys().asSequence().associateWith { k -> o.opt(k) as? String ?: throw NotDictionaryFile() }
            return fromPlain(plain)
        }
    }

    /** 目前有效的字典。 */
    val live: Map<String, String> get() = entries.mapNotNull { (k, v) -> v.output?.let { k to it } }.toMap()

    fun set(source: String, output: String, at: Double): DictionarySync {
        val s = source.trim()
        if (s.isEmpty()) return this
        val o = output.trim()
        return DictionarySync(entries + (s to Entry(o.ifEmpty { s }, at)))
    }

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
        for ((k, v) in entries.toSortedMap()) e.put(k, JSONObject().put("at", v.at).apply { v.output?.let { put("output", it) } })
        return JSONObject().put("format", FORMAT).put("version", VERSION).put("entries", e).toString(2)
    }
}
