package com.utuvo.type

import android.icu.text.Transliterator

/**
 * 自動學字典（同 iOS CorrectionLearner）：剛用語音貼上一段字，接著用本鍵盤刪掉幾個字、
 * 再打回同樣字數、每個字讀音相同（除值→儲值）＝辨識錯字，記進個人字典。
 * 改主意（讀音不同）、只有一個字、刪的不是剛聽寫那段 → 不學。
 */
class CorrectionLearner(private val now: () -> Long = { System.currentTimeMillis() }) {
    companion object {
        const val WINDOW_MS = 90_000L
        const val MAX_LENGTH = 6
        private val pronouns = setOf('他', '她', '它', '牠', '祂', '你', '妳', '您')
        private val toPinyin: Transliterator by lazy { Transliterator.getInstance("Han-Latin; Latin-ASCII; Lower") }

        fun isCJK(c: Char) = c.code in 0x3400..0x9FFF || c.code in 0xF900..0xFAFF
        fun pinyin(c: Char): String = toPinyin.transliterate(c.toString()).trim()
        fun isHomophone(a: Char, b: Char) =
            a != b && isCJK(a) && isCJK(b) && !(a in pronouns && b in pronouns) && pinyin(a) == pinyin(b)

        fun evaluate(deleted: String, typed: String, dictated: String): Pair<String, String>? {
            val d = deleted.trim(); val r = typed.trim()
            if (d == r || d.length != r.length || d.length !in 2..MAX_LENGTH || !dictated.contains(d)) return null
            if (!d.indices.all { d[it] == r[it] || isHomophone(d[it], r[it]) }) return null
            return d to r
        }
    }

    var dictated = ""; private set
    private var dictatedAt = 0L
    private var deleted = StringBuilder()
    private var typed = StringBuilder()

    fun dictationInserted(text: String) { dictated = text; dictatedAt = now(); deleted.clear(); typed.clear() }

    private fun active() = dictated.isNotEmpty() && now() - dictatedAt <= WINDOW_MS

    /** 刪掉游標前一個字之前呼叫。 */
    fun willDelete(charBefore: Char?) {
        if (!active()) return
        if (typed.isNotEmpty()) { typed.setLength(typed.length - 1); return }
        if (charBefore == null || charBefore.isWhitespace()) return
        deleted.insert(0, charBefore)
        if (deleted.length > MAX_LENGTH * 2) { deleted.clear(); typed.clear() }
    }

    /** 用鍵盤送出文字後呼叫；打回的字數到了就結算。 */
    fun didType(text: String): Pair<String, String>? {
        if (!active() || deleted.isEmpty()) return null
        typed.append(text)
        if (typed.length < deleted.length) return null
        val result = evaluate(deleted.toString(), typed.toString(), dictated)
        deleted.clear(); typed.clear()
        return result
    }
}
