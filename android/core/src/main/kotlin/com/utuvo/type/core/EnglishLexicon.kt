package com.utuvo.type.core

/**
 * 內附英文詞表的查詢：補完（以打的字開頭的字）與拼字建議（一次編輯距離內的字），都依常用度排。
 * 對應 iOS UITextChecker 的 completions／guesses；Android 系統拼字服務不做補完、字典也可能沒載入，
 * 所以 Android 用這份詞表（`english-words.txt`，由 scripts/build-english-words.py 從 SCOWL 產生）。
 *
 * `rankedWords`：一行一個字，越前面越常用（行號＝排名）。同一個字不分大小寫只會出現一次。
 * 回傳的字保留詞表裡的寫法（Monday、I、don't）；配合使用者大小寫由 [EnglishSuggestions.merge] 處理。
 */
class EnglishLexicon(rankedWords: List<String>) {
    private val words: Array<String>
    /** 小寫 → 排名。 */
    private val rank: HashMap<String, Int>
    /** 依小寫字母序排好的索引（指到 [words]），給前綴二分搜尋用。 */
    private val sorted: IntArray
    private val sortedKeys: Array<String>

    init {
        val list = ArrayList<String>(rankedWords.size)
        rank = HashMap(rankedWords.size * 2)
        for (w in rankedWords) {
            val t = w.trim()
            if (t.isEmpty()) continue
            val lower = t.lowercase()
            if (rank.containsKey(lower)) continue
            rank[lower] = list.size
            list.add(t)
        }
        words = list.toTypedArray()
        sorted = words.indices.sortedBy { words[it].lowercase() }.toIntArray()
        sortedKeys = Array(sorted.size) { words[sorted[it]].lowercase() }
    }

    val size: Int get() = words.size

    /** 詞表裡有沒有這個字（不分大小寫）。 */
    fun contains(word: String): Boolean = rank.containsKey(word.lowercase())

    /** 以 `prefix` 開頭（不分大小寫）、比它長的字，常用的在前。 */
    fun completions(prefix: String, limit: Int): List<String> {
        if (prefix.isEmpty() || limit <= 0) return emptyList()
        val p = prefix.lowercase()
        var lo = lowerBound(p)
        val hits = ArrayList<Int>()
        while (lo < sortedKeys.size && sortedKeys[lo].startsWith(p)) {
            if (sortedKeys[lo].length > p.length) hits.add(sorted[lo])
            lo++
        }
        hits.sort()   // 索引就是排名
        return hits.take(limit).map { words[it] }
    }

    /**
     * 拼字建議：跟 `word` 差一次編輯（刪一個字母、多一個、換一個、相鄰對調）的字。
     * 相鄰對調（teh→the）是手指打太快最常見的錯，排最前面；其餘依常用度（詞表同一級內沒有詞頻，
     * 只靠常用度會讓 teh 先建議 tea）。字本身在詞表裡就不給建議（同 UITextChecker：拼對的字沒有 guesses）。
     */
    fun guesses(word: String, limit: Int): List<String> {
        if (word.isEmpty() || limit <= 0) return emptyList()
        val w = word.lowercase()
        if (rank.containsKey(w)) return emptyList()
        // 排名 → 這個字是不是由相鄰對調得來（對調的排前面）
        val found = HashMap<Int, Boolean>()
        fun probe(s: String, swapped: Boolean = false) {
            val r = rank[s] ?: return
            found[r] = swapped || found[r] == true
        }
        val sb = StringBuilder()
        for (i in w.indices) {
            probe(w.removeRange(i, i + 1))                                   // 刪
            if (i + 1 < w.length) {                                          // 對調
                sb.setLength(0); sb.append(w); val c = sb[i]; sb[i] = sb[i + 1]; sb[i + 1] = c
                probe(sb.toString(), swapped = true)
            }
        }
        for (i in 0..w.length) {
            for (c in LETTERS) {
                probe(w.substring(0, i) + c + w.substring(i))                // 插
                if (i < w.length && w[i] != c) probe(w.substring(0, i) + c + w.substring(i + 1))  // 換
            }
        }
        return found.entries.sortedWith(compareBy({ !it.value }, { it.key })).take(limit).map { words[it.key] }
    }

    private fun lowerBound(key: String): Int {
        var lo = 0
        var hi = sortedKeys.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (sortedKeys[mid] < key) lo = mid + 1 else hi = mid
        }
        return lo
    }

    private companion object {
        val LETTERS = ('a'..'z').toList() + '\''
    }
}
