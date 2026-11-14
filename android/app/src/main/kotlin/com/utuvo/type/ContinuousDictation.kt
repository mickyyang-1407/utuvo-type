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
        // 換句的訊號：即時結果歸零（模擬器實測）；或沒有歸零、直接跳到更短而且開頭不同的下一句
        // （別家辨識器可能不送空的即時結果——review 指出）。即時改字（"I will" → "I'll"）開頭相同，不算換句。
        // 以前要「短一半以上」才算：Pixel 重聽前一句後半段時新句沒短那麼多，前一句整句被丟（2026-11-01）。
        // 現在只要更短就收起前一句；萬一其實是同一句的改寫，接句時的重疊合併（[join]）會把重複收掉。
        val reset = lastPartial.isNotEmpty() &&
            (t.isEmpty() || (t.length < lastPartial.length && commonPrefix(t, lastPartial) < 2))
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
         * 段落相接：下一段開頭是拉丁字母／數字、而前一段結尾是拉丁字母／數字或英文標點時補一個空白
         * （"hello" + "world" → "hello world"、"Hi." + "How" → "Hi. How"）；中文標點後面不補。
         * 段落邊界是辨識器偵測到的停頓：中文接中文照停頓規則補「，」（前一小句夠長、不是講到一半），
         * 永遠不補句號；以前直接黏起來，長句會變成一長串沒有標點的字（2026-11-01，見 PauseJoin）。
         * 下一段開頭跟前文結尾重疊（辨識器重聽）時從重疊處接，見 [overlapStart]。
         */
        fun join(parts: List<String>): String {
            val out = StringBuilder()
            for (p in parts) {
                if (p.isEmpty()) continue
                if (out.isNotEmpty()) {
                    when (val cut = overlapStart(out, p)) {
                        ALREADY_THERE -> continue
                        NO_OVERLAP -> {}
                        else -> { out.setLength(cut); while (out.isNotEmpty() && out.last() == ' ') out.setLength(out.length - 1) }
                    }
                }
                if (out.isNotEmpty()) {
                    val a = out.last(); val b = p.first()
                    if (isLatinWord(b) && (isLatinWord(a) || a in ".,!?;:")) out.append(' ')
                    else out.append(com.utuvo.type.core.PauseJoin.mark(out.toString(), p))
                }
                out.append(p)
            }
            return out.toString()
        }

        private const val NO_OVERLAP = -1
        private const val ALREADY_THERE = -2
        /** 重疊至少要這麼長才算（短詞如「好」「對對對」真的會重複講，不能吃掉）。 */
        private const val MIN_OVERLAP = 6
        /** 只在前文最後這麼多字裡找（辨識器重聽的只會是剛剛那幾句）。 */
        private const val TAIL_WINDOW = 160

        /**
         * 新的一段開頭跟前文結尾重疊的位置。Pixel 實測（2026-11-01 Micky 截圖）：辨識器重開一段或換句時，
         * 會把前一句的後半段再聽一次、還改幾個字（「…我想要做一個網站嗎」→ 新段「就是除了…我想要做一個可以讓人家看的網站嗎」），
         * 直接接上＝同一段話出現三次。新段開頭在前文結尾附近找得到 → 前文從那裡截斷、改用新段（新段是較新的辨識）；
         * 新段整句已經在前文結尾附近 → 跳過。
         */
        private fun overlapStart(acc: CharSequence, next: String): Int {
            if (next.length < MIN_OVERLAP) return NO_OVERLAP
            val from = maxOf(0, acc.length - TAIL_WINDOW)
            // 比對時拿掉停頓補的「，」（PauseJoin.mark）：重聽的那段可能跨過我們剛補的逗號，
            // 「網站嗎，就是除了」對「網站嗎就是除了」要認得出來（2026-11-14 併停頓逗號＋重聽合併時補）。
            // `at[i]`＝去掉逗號後第 i 個字在 acc 裡的位置。
            val at = ArrayList<Int>()
            val tail = StringBuilder()
            for (i in from until acc.length) if (acc[i] != PAUSE_MARK) { tail.append(acc[i]); at.add(i) }
            val probe = next.filter { it != PAUSE_MARK }
            if (probe.length < MIN_OVERLAP) return NO_OVERLAP
            // 拉丁字母開頭的段落只認整字對齊（"rehearsal" 不能從 "hearsal" 接）。
            fun aligned(i: Int) = !isLatinWord(probe.first()) || at[i] == 0 || !isLatinWord(acc[at[i] - 1])
            var i = tail.indexOf(probe)
            while (i >= 0) { if (aligned(i)) return ALREADY_THERE; i = tail.indexOf(probe, i + 1) }
            for (k in minOf(probe.length - 1, tail.length) downTo MIN_OVERLAP) {
                val head = probe.substring(0, k)
                var j = tail.lastIndexOf(head)
                while (j >= 0) { if (aligned(j)) return at[j]; j = if (j == 0) -1 else tail.lastIndexOf(head, j - 1) }
            }
            return NO_OVERLAP
        }

        /** PauseJoin 在停頓處補的標點。 */
        private const val PAUSE_MARK = '，'

        private fun isLatinWord(c: Char) = c.code < 128 && c.isLetterOrDigit()

        private fun commonPrefix(a: String, b: String): Int {
            var i = 0
            while (i < a.length && i < b.length && a[i] == b[i]) i++
            return i
        }
    }
}
