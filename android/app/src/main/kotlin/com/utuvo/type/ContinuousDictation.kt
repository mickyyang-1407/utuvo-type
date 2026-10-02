package com.utuvo.type

/**
 * 一次聽寫＝從點光球到再點一次光球（同 iOS）。Android 的系統辨識器聽到一小段靜音就自己送出最終結果並結束，
 * 以前鍵盤收到結果就當成講完了——講到一半停頓一下，聽寫就斷掉（2026-10-01 Micky：「只要稍微停頓一下就會自動結束」）。
 *
 * 這個類別只管邏輯（不碰 Android API，JVM 測試直接餵）：辨識器每結束一段就交回一段文字，
 * 使用者還沒按停就重新開始聽；按停之後最後一段回來，才把所有段落接起來一次送出（只貼一次）。
 * 連續 [maxSilenceMillis] 都沒聽到任何字才自動收尾（忘了關麥克風的保護，正常停頓碰不到）。
 */
class ContinuousDictation(
    private val maxSilenceMillis: Long = 60_000,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val segments = mutableListOf<String>()
    private var lastSpeechAt = now()
    /** 使用者已經按了停：下一個回來的結果就是最後一段。 */
    var stopRequested = false
        private set

    /** 辨識器一段結束後該做什麼。 */
    enum class Next { RESTART, FINISH }

    /**
     * 同一次辨識裡，停頓之後即時結果會整個歸零、從下一句重新開始（模擬器實測：
     * 「…afternoon」→「」→「 remember…」），而且最終結果常常是空的——只拿最後一次即時結果，前一句就不見了。
     * 所以即時結果「從有字變成空」＝前一句講完：先收進 [runUtterances]，這一段結束時再接回去。
     */
    private val runUtterances = mutableListOf<String>()
    private var lastPartial = ""

    /** 收到一次即時結果。回傳預覽要顯示的整段文字。 */
    fun partial(text: String): String {
        val t = text.trim()
        // 換句的訊號：即時結果歸零（模擬器實測）；或沒有歸零、直接跳到明顯更短而且開頭不同的下一句
        // （別家辨識器可能不送空的即時結果——review 指出）。即時改字（"I will" → "I'll"）開頭相同，不算換句。
        val reset = lastPartial.isNotEmpty() &&
            (t.isEmpty() || (t.length * 2 < lastPartial.length && commonPrefix(t, lastPartial) < 2))
        if (reset) runUtterances += lastPartial
        lastPartial = t
        return preview(t)
    }

    /**
     * 這一段（辨識器這次 startListening）的完整文字：最終結果有字而且已經包含前面收起來的句子就用它；
     * 否則把收起來的句子接上（最終結果或最後一次即時結果）。用完清空，下一段重新算。
     */
    fun segmentText(final: String): String {
        val tail = final.trim().ifEmpty { lastPartial }
        val earlier = runUtterances.toList()
        runUtterances.clear(); lastPartial = ""
        if (earlier.isEmpty()) return tail
        // 最終結果已經涵蓋前面的句子：整句都在，或開頭跟第一句相同（最終結果常把前句改幾個字，例「錄音事」→「錄音室」，
        // 只比「包含」會把改過的前句再接一次＝重複貼上——review 指出）。
        if (tail.isNotEmpty() && (earlier.all { tail.contains(it) } || commonPrefix(tail, earlier.first()) >= 2)) return tail
        return join(earlier + listOf(tail).filter { it.isNotEmpty() })
    }

    /** 已經聽到的文字（即時預覽用：前面幾段＋這一段已收起來的句子＋目前的即時結果）。 */
    fun preview(partial: String = ""): String =
        join(segments + runUtterances + listOf(partial.trim()).filter { it.isNotEmpty() })

    fun requestStop() { stopRequested = true }

    /** 一段有結果（可能是空的）。回傳要重新開始聽，還是收尾。 */
    fun onSegment(text: String): Next {
        val t = text.trim()
        if (t.isNotEmpty()) { segments += t; lastSpeechAt = now() }
        return decide()
    }

    /** 這一段沒聽到字（系統的 NO_MATCH／SPEECH_TIMEOUT）：不算錯，照樣繼續聽，除非已經按停或太久沒講話。 */
    fun onSilence(): Next = decide()

    private fun decide(): Next =
        if (stopRequested || now() - lastSpeechAt >= maxSilenceMillis) Next.FINISH else Next.RESTART

    /** 收尾：所有段落接成一段（加上最後一段，如果還有）。 */
    fun finish(lastSegment: String = ""): String {
        val t = lastSegment.trim()
        if (t.isNotEmpty()) segments += t
        return join(segments)
    }

    companion object {
        /**
         * 段落相接：中文直接接；下一段開頭是拉丁字母／數字、而前一段結尾是拉丁字母／數字或英文標點時補一個空白
         * （"hello" + "world" → "hello world"、"Hi." + "How" → "Hi. How"）；中文標點後面不補。
         */
        fun join(parts: List<String>): String {
            val out = StringBuilder()
            for (p in parts) {
                if (p.isEmpty()) continue
                if (out.isNotEmpty()) {
                    val a = out.last(); val b = p.first()
                    if (isLatinWord(b) && (isLatinWord(a) || a in ".,!?;:")) out.append(' ')
                }
                out.append(p)
            }
            return out.toString()
        }

        private fun isLatinWord(c: Char) = c.code < 128 && c.isLetterOrDigit()

        private fun commonPrefix(a: String, b: String): Int {
            var i = 0
            while (i < a.length && i < b.length && a[i] == b[i]) i++
            return i
        }
    }
}
