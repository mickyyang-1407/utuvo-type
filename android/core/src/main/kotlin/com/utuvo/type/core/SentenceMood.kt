package com.utuvo.type.core

/**
 * 句尾語氣（Swift `Sources/UTUVOTypeCore/SentenceMood.swift` 的逐條移植；golden 由 Swift 匯出比對）。
 *
 * 2026-10-02 Micky：「不要每個句子或最後都用句點，偶爾可以有問號、驚嘆號……一直使用句點會顯得很 AI」。
 * - 問句 →「？」、明確的感嘆 →「！」；拿不準就維持句號。只改「。」結尾的句子。
 * - [finish]：再把最後一句的「。」拿掉（整段沒有換行時）。
 * - [continuationPrefix]：緊接著上一段再講時，把拿掉的句號補回去。
 */
object SentenceMood {

    fun finish(text: String): String = dropFinalPeriod(apply(text))

    fun apply(text: String): String {
        if (!text.contains("。") && !text.contains(".")) return text
        val out = StringBuilder()
        for (sentence in Normalizer.splitSentences(text)) out.append(retune(sentence))
        return out.toString()
    }

    fun dropFinalPeriod(text: String): String {
        if (text.contains("\n")) return text
        var end = text.length
        while (end > 0 && text[end - 1].isWhitespace()) end--
        if (end == 0 || text[end - 1] != '。') return text
        val without = text.substring(0, end - 1)
        if (without.none { it.isLetterOrDigit() }) return text
        return without + text.substring(end)
    }

    fun continuationPrefix(before: String?, previous: String?): String {
        if (before == null || previous.isNullOrEmpty()) return ""
        val trimmedBefore = before.replace(Regex("\\s+$"), "")
        if (!trimmedBefore.endsWith(previous)) return ""
        return if (isCJKLetter(previous.last())) "。" else ""
    }

    private fun isCJKLetter(c: Char): Boolean = c.code in 0x3400..0x9FFF || c.code in 0xF900..0xFAFF

    // ── 單句 ──

    internal fun retune(sentence: String): String {
        var end = sentence.length
        while (end > 0 && sentence[end - 1].isWhitespace()) end--
        if (end == 0) return sentence
        val mark = sentence[end - 1]
        if (mark != '。' && mark != '.') return sentence
        val core = sentence.substring(0, end - 1)
        val tail = sentence.substring(end)
        if (mark == '.') return if (isEnglishQuestion(core)) "$core?$tail" else sentence
        if (isQuestion(core)) return "$core？$tail"
        if (isExclamation(core)) return "$core！$tail"
        return sentence
    }

    // ── 問句 ──

    private val subjects = setOf("你", "妳", "您", "他", "她", "它", "我", "我們", "我们", "你們", "你们",
        "他們", "他们", "她們", "大家", "這個", "这个", "那個", "那个", "這", "那")
    private val concessives = listOf("不管", "無論", "无论", "不論", "不论", "隨便", "随便", "任何")
    private val embedders = listOf("知道", "曉得", "明白", "清楚", "看得出", "跟你說", "跟他說", "跟妳說", "告訴你", "看你", "看他", "看妳", "看大家", "看情況", "不確定", "不曉得", "想知道", "看看", "問問", "問他", "問她", "問你", "問一下",
        "確認", "決定", "考慮", "記得", "忘了", "告訴", "說明", "解釋", "查一下", "討論", "研究", "了解")
    private val interrogatives = listOf("什麼", "什么", "怎麼", "怎么", "為什麼", "为什么", "為何", "哪裡", "哪里", "哪個", "哪个",
        "哪些", "哪一", "誰", "谁", "多少", "幾點", "几点", "幾個", "几个", "幾天", "几天", "如何", "何時", "多久", "多大", "多遠")
    private val aNotA = listOf("是不是", "有沒有", "有没有", "要不要", "會不會", "会不会", "能不能", "可不可以", "對不對", "对不对",
        "好不好", "行不行", "可以嗎", "可以吗", "是否", "還是不", "去不去", "來不來", "来不来")
    private val pronounFollowUp = Regex("^(那|那麼|那么)?(你|妳|您|我|他|她|它|你們|你们|我們|我们|他們|他们|這個|这个|那個|那个|這邊|那邊)呢$")
    private val indefinite = Regex("(什麼|什么|誰|谁|哪裡|哪里|哪個|哪个|怎麼樣|怎么样|多少|幾個|几个)[^，,。]{0,4}(都|也)")

    internal fun isQuestion(core: String): Boolean {
        val s = core.trim(' ', '\t')
        if (s.isEmpty()) return false
        val clause = lastClause(s)
        if (clause.endsWith("嗎") || clause.endsWith("吗")) return true
        if (clause.endsWith("對吧") || clause.endsWith("对吧") || clause.endsWith("是吧") || clause.endsWith("好嗎")) return true
        if (clause.endsWith("呢")) {
            if (pronounFollowUp.containsMatchIn(clause)) return true
            return containsInterrogative(clause) && !isEmbedded(clause)
        }
        if (concessives.any { clause.contains(it) }) return false
        val hit = aNotA.mapNotNull { a -> clause.indexOf(a).takeIf { it >= 0 }?.let { it to a } }.minByOrNull { it.first }
        if (hit != null) {
            if (isEmbedded(clause, hit.first)) return false
            return clause.length - (hit.first + hit.second.length) <= 6
        }
        if (isEmbedded(clause) || indefinite.containsMatchIn(clause)) return false
        for (q in interrogatives) {
            var from = 0
            while (true) {
                val i = clause.indexOf(q, from)
                if (i < 0) break
                val after = clause.length - (i + q.length)
                val prefix = clause.substring(0, i)
                if (prefix.isEmpty() || prefix in subjects || after <= 3) return true
                from = i + q.length
            }
        }
        return false
    }

    private fun lastClause(s: String): String {
        val breakers = setOf('，', ',', '；', ';', '：', ':')
        val i = s.indexOfLast { it in breakers }
        if (i >= 0) {
            val rest = s.substring(i + 1).trim(' ', '\t')
            if (rest.isNotEmpty()) return rest
        }
        return s
    }

    private fun containsInterrogative(s: String) = interrogatives.any { s.contains(it) }

    /** 疑問詞（或指定位置）前面出現「不知道／問問／看看……」＝間接問句。 */
    private fun isEmbedded(s: String, limit: Int? = null): Boolean {
        val firstQ = limit ?: (interrogatives.mapNotNull { q -> s.indexOf(q).takeIf { it >= 0 } }.minOrNull() ?: s.length)
        val head = s.substring(0, firstQ)
        return embedders.any { head.contains(it) }
    }

    // ── 感嘆 ──

    private val exclamations = listOf("好棒", "超棒", "太棒", "好厲害", "太厲害", "好可愛", "太可愛", "天啊", "天哪", "我的天",
        "恭喜", "加油", "太好了", "好開心", "太開心", "好感動", "謝謝你", "謝謝大家", "感謝大家",
        "哈哈", "生日快樂", "新年快樂", "辛苦了", "好好吃", "好好喝", "真的假的", "不會吧")
    private val tooMuch = Regex("(?<!不)太[^，,。！？]{1,6}了(啦|吧|啊)?$")
    private val soMuch = Regex("^.{0,3}好[^，,。]{1,4}(喔|哦|啊|呀)$")

    internal fun isExclamation(core: String): Boolean {
        val clause = lastClause(core.trim(' ', '\t'))
        if (exclamations.any { clause.contains(it) }) return true
        if (tooMuch.containsMatchIn(clause)) return true
        if (SwiftText.graphemes(clause).size <= 10 && soMuch.containsMatchIn(clause)) return true
        return false
    }

    // ── 英文 ──

    private val englishQuestionStarts = setOf("what", "why", "how", "when", "where", "who", "which", "can", "could", "would",
        "will", "do", "does", "did", "is", "are", "should", "may", "shall", "have", "has")

    internal fun isEnglishQuestion(core: String): Boolean {
        val trimmed = core.trim(' ', '\t')
        if (trimmed.codePoints().anyMatch { it in 0x3400..0x9FFF }) return false
        val first = trimmed.split(Regex("[^\\p{L}']+")).firstOrNull { it.isNotEmpty() }?.lowercase() ?: ""
        return first in englishQuestionStarts
    }
}
