package com.utuvo.type.core

/**
 * 句尾語氣（Swift `Sources/UTUVOTypeCore/SentenceMood.swift` 的逐條移植；golden 由 Swift 匯出比對）。
 *
 * 2026-10-02 Micky：「不要每個句子或最後都用句點，偶爾可以有問號、驚嘆號……一直使用句點會顯得很 AI」。
 * - 問句 →「？」、明確的感嘆 →「！」；拿不準就維持句號。只改「。」結尾的句子。
 * - [finish]：再把最後一句的「。」拿掉（整段沒有換行時）。
 * - [continuationPrefix]：緊接著上一段再講時，把拿掉的句號補回去（舊規則，Android 鍵盤 W2-7 起改用 [joinPrefix]）。
 * - [joinPrefix]／[finishDroppedMark]：接續聽寫（同 Mac）——永遠不補「。」，只補英數字之間的空白與上一段被拿掉的「，」「、」。
 */
object SentenceMood {

    fun finish(text: String): String = dropFinalPeriod(apply(text))

    fun apply(text: String): String {
        if (!text.contains("。") && !text.contains(".")) return text
        val out = StringBuilder()
        for (sentence in Normalizer.splitSentences(text)) out.append(retune(sentence))
        return out.toString()
    }

    /**
     * 最後一句的句號拿掉（同 Swift：只拿「。」，句尾吊著的「，」「、」也拿；有換行＝分段長文，照原樣）。
     * W2-7（2026-10-22）改成逐字形叢集看，跟 Swift 的 `Character` 一致：`contains("\n")` 比的是字（「\r\n」是一個字、不算換行）、
     * 尾巴的空白一個字一個字剝（「 \u0301」也是空白）、「有沒有字」看 Alphabetic／數字（「①」「Ⅻ」也算）。
     * [finishDroppedMark] 回報的就是這裡拿掉的那個標點，兩邊要逐字一樣。
     */
    fun dropFinalPeriod(text: String): String {
        val g = SwiftText.graphemes(text)
        if ("\n" in g) return text
        var end = g.size
        while (end > 0 && SwiftText.isWhitespace(g[end - 1])) end--
        if (end == 0 || g[end - 1] !in finalMarks) return text
        val without = g.subList(0, end - 1)
        if (without.none { isLetterOrNumber(it) }) return text
        return without.joinToString("") + g.subList(end, g.size).joinToString("")
    }

    private val finalMarks = setOf("。", "，", "、")

    /** Swift `Character.isLetter || .isNumber`：第一個 scalar 有 Alphabetic 屬性、或是數字類。 */
    private fun isLetterOrNumber(g: String): Boolean = Character.isAlphabetic(g.codePointAt(0)) || SwiftText.isNumber(g)

    fun continuationPrefix(before: String?, previous: String?): String {
        if (before == null || previous.isNullOrEmpty()) return ""
        val trimmedBefore = before.replace(Regex("\\s+$"), "")
        if (!trimmedBefore.endsWith(previous)) return ""
        return if (isCJKLetter(previous.last())) "。" else ""
    }

    /**
     * 接續聽寫（W2-7，2026-10-22；Swift `SentenceMood.joinPrefix` 的逐條移植，Mac 第三輪審查的保守規則）：
     * 游標前正好是上一段聽寫的結尾（同一個欄位、游標沒動）時，這一段前面要先插什麼。
     * - 永遠不插「。」（或任何句末標點）：辨識器幾乎每段都收在「。」，話講到一半停住也一樣，
     *   插句號會把一句話切成兩句（「我要。一杯咖啡」「我的老闆。明天要來」）。
     * - 中文接中文：什麼都不插（「我要」＋「一杯咖啡」→「我要一杯咖啡」）。
     * - 英數字接英數字（上一段尾是英數字或 .!?,;:，這一段頭是英數字）：插一個空白，免得黏成一個字。
     * - [droppedMark]（[finish] 拿掉的句尾標點，見 [finishDroppedMark]）是「，」「、」就原樣補回；拿掉的是「。」不補。
     * - 游標前最後一個字是空白、讀不到游標前（null）、游標前不是上一段的結尾：什麼都不插。
     * 「字」一律照 Swift 的 `Character`（字形叢集）：emoji、組合記號在交界上跟 Swift 逐字一樣（golden sentence-mood-join.json）。
     */
    fun joinPrefix(before: String?, previous: String?, next: String, droppedMark: String? = null): String {
        if (before == null || previous.isNullOrEmpty()) return ""
        val lastBefore = SwiftText.graphemes(before).lastOrNull() ?: return ""
        if (SwiftText.isWhitespace(lastBefore)) return ""
        if (!SwiftText.hasSuffix(before, previous)) return ""
        if (droppedMark == "，" || droppedMark == "、") return droppedMark
        val tail = SwiftText.graphemes(previous).last()
        val head = SwiftText.graphemes(next).firstOrNull() ?: return ""
        if ((isASCIIWordCharacter(tail) || tail in asciiJoiners) && isASCIIWordCharacter(head)) return " "
        return ""
    }

    /**
     * [finish] 會拿掉的句尾標點（「。」「，」「、」）；不拿就回空字串（Swift `SentenceMood.finishDroppedMark`）。
     * 接續聽寫把它記下來當 [joinPrefix] 的 `droppedMark`：下一段緊接著講時，「，」「、」原樣補回（「。」不補）。
     */
    fun finishDroppedMark(text: String): String {
        val applied = apply(text)
        if (dropFinalPeriod(applied) == applied) return ""
        return SwiftText.graphemes(applied).lastOrNull { !SwiftText.isWhitespace(it) } ?: ""
    }

    private val asciiJoiners = setOf(".", "!", "?", ",", ";", ":")

    /** Swift `c.isASCII && (c.isLetter || c.isNumber)`：單一個 ASCII 英數字（後面黏組合記號的「a\u0301」不算）。 */
    private fun isASCIIWordCharacter(g: String): Boolean = g.length == 1 && g[0].code < 0x80 && g[0].isLetterOrDigit()

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
