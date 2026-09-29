package com.utuvo.type.core

/** Conservative punctuation fallback for recognizers that ignore EXTRA_ENABLE_FORMATTING. */
object SpeechPunctuation {
    enum class Field { DOCUMENT, CHAT, SEARCH }

    private val terminal = setOf('。', '！', '？', '.', '!', '?')
    private val boundary = setOf('，', '。', '！', '？', ',', '.', '!', '?', '\n')
    private val transitions = listOf("但是", "不過", "可是", "所以", "因此", "另外", "接著")
    private val questionOpeners = listOf("請問", "為什麼", "怎麼", "如何", "哪裡", "哪個", "誰", "什麼時候", "可不可以", "能不能", "要不要")
    private val questionEndings = listOf("什麼", "什么", "哪裡", "哪里", "幾點", "几点", "多少", "怎麼辦", "怎么办")

    fun restore(text: String, field: Field): String {
        if (field == Field.SEARCH || text.none(::isHan)) return text
        var result = text.trim()
        if (result.isEmpty()) return text

        // Only split at explicit changes of thought. A character count alone cannot reveal a pause.
        for (marker in transitions) {
            var from = 0
            while (true) {
                val index = result.indexOf(marker, from)
                if (index < 0) break
                val clause = result.substring(0, index).takeLastWhile { it !in boundary }
                val next = index + marker.length
                if (clause.count(::isHan) >= 5 && result.substring(next).count(::isHan) >= 2 &&
                    result.getOrNull(index - 1) !in boundary
                ) {
                    result = result.substring(0, index) + "，" + result.substring(index)
                    from = next + 1
                } else {
                    from = next
                }
            }
        }

        if (result.last() in terminal) return result
        val embeddedQuestion = questionEndings.any(result::endsWith) &&
            !result.startsWith("我想知道") && !result.startsWith("不知道")
        val question = result.endsWith("嗎") || result.endsWith("吗") || result.endsWith("呢") ||
            questionOpeners.any(result::startsWith) || result.startsWith("你要不要") || embeddedQuestion
        if (question) return result.trimEnd('，', ',') + "？"
        if (field == Field.DOCUMENT && result.count(::isHan) >= 4 && result.last() !in boundary) return "$result。"
        return result
    }

    private fun isHan(char: Char): Boolean = char in '\u3400'..'\u9fff'
}
