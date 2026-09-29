package com.utuvo.type.core

/**
 * 英文鍵盤建議列的純邏輯（不碰 UI）：找出游標前正在打的字、合併各來源的建議、配合使用者的大小寫。
 * 拼字檢查與補完的來源（iOS 的 UITextChecker）由鍵盤那一層提供，這裡只負責排序與去重。
 */
object EnglishSuggestions {
    /** 建議列最多幾格。 */
    const val DEFAULT_LIMIT = 8

    /** 可以組成「一個字」的字元：ASCII 字母，以及夾在字母中間的撇號（don't、it's）。 */
    fun isWordCharacter(c: Char): Boolean = (c.isAsciiLetter()) || c == '\'' || c == '’'

    /** 游標前正在打的那個字（結尾連續的字母；開頭的撇號不算）。游標前是空白、標點、數字時回空字串。 */
    fun currentWord(before: String?): String {
        if (before == null) return ""
        val word = StringBuilder()
        for (i in before.indices.reversed()) {
            if (!isWordCharacter(before[i])) break
            word.append(before[i])
        }
        val s = word.reverse().toString()
        var start = 0
        while (start < s.length && (s[start] == '\'' || s[start] == '’')) start++
        return s.substring(start)
    }

    /**
     * 合併建議：
     * 1. 使用者自己的詞（個人字典、聯絡人姓名、文字替換）裡以這個字開頭的——最懂使用者；
     * 2. 拼錯時：拼字建議（guesses）優先，否則補完（completions）優先；
     * 3. 去掉跟打的字一模一樣的（不分大小寫）、重複的；
     * 4. 依使用者打的大小寫調整（Hel → Hello、HEL → HELLO）；使用者詞保留原本的寫法（iPhone、McBopomofo）。
     */
    fun merge(
        word: String,
        isMisspelled: Boolean,
        completions: List<String>,
        guesses: List<String>,
        userTerms: List<String>,
        limit: Int = DEFAULT_LIMIT,
    ): List<String> {
        if (word.isEmpty() || limit <= 0) return emptyList()
        val lower = word.lowercase()
        val out = ArrayList<String>()
        val seen = HashSet<String>()
        seen.add(lower)
        fun append(s: String, keepCase: Boolean) {
            if (out.size >= limit || s.isEmpty()) return
            val shown = if (keepCase) s else matchCase(s, word)
            if (seen.add(shown.lowercase())) out.add(shown)
        }
        for (t in userWords(lower, userTerms)) append(t, true)
        val first = if (isMisspelled) guesses else completions
        val second = if (isMisspelled) completions else guesses
        for (s in first) append(s, false)
        for (s in second) append(s, false)
        return out
    }

    /** 使用者詞庫裡以 `prefix`（小寫）開頭、而且比它長的字。多字詞拆成單字比對（「Dolby Atmos」→ Dolby、Atmos）。 */
    internal fun userWords(prefix: String, terms: List<String>): List<String> {
        val out = ArrayList<String>()
        for (term in terms) {
            val current = StringBuilder()
            fun flush() {
                val s = current.toString()
                current.setLength(0)
                if (s.length > prefix.length && s.lowercase().startsWith(prefix) && s.all { isWordCharacter(it) }) out.add(s)
            }
            for (c in term) {
                if (isWordCharacter(c)) current.append(c) else flush()
            }
            flush()
        }
        return out
    }

    /** 依使用者打的樣子調整大小寫：全大寫（兩個字母以上）→ 全大寫；首字大寫 → 首字大寫；其他照建議原樣。 */
    fun matchCase(suggestion: String, typed: String): String {
        val first = typed.firstOrNull() ?: return suggestion
        if (!first.isUpperCaseChar()) return suggestion
        if (typed.length > 1 && typed.all { !it.isLetterChar() || it.isUpperCaseChar() }) return suggestion.uppercase()
        return suggestion.take(1).uppercase() + suggestion.drop(1)   // 空字串也安全（同 Swift prefix/dropFirst）
    }

    private fun Char.isAsciiLetter() = this in 'a'..'z' || this in 'A'..'Z'
    private fun Char.isUpperCaseChar() = this in 'A'..'Z'
    private fun Char.isLetterChar() = this in 'a'..'z' || this in 'A'..'Z' || this.code in 0xC0..0x24F
}
