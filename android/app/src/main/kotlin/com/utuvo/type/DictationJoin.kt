package com.utuvo.type

import com.utuvo.type.core.SentenceMood

/**
 * 接續聽寫（W2-7，2026-10-22；同 Mac AppModel 的 continuation＋[SentenceMood.joinPrefix]）：
 * 游標還停在上一段聽寫的結尾、使用者又接著講時，這一段前面要先插什麼。
 *
 * 以前用 [SentenceMood.continuationPrefix]：上一段結尾是中文字就補「。」。辨識器在停頓處就交回一段、話講到一半也一樣，
 * 一句話被切成兩句（「我要。一杯咖啡」「我的老闆。明天要來」）。現在跟 Mac 同一條保守規則：
 * 永遠不補「。」；中文接中文什麼都不插；英數字接英數字補一個空白；上一段送出前被拿掉的「，」「、」原樣補回。
 *
 * 純邏輯，JVM 測得到（DictationJoinTest）。
 */
internal object DictationJoin {
    /**
     * 上一段聽寫：插入的文字（不含它自己的前綴）＋送出前被拿掉的句尾標點
     * （[SentenceMood.finishDroppedMark]：「。」「，」「、」或空字串）。
     */
    data class Previous(val text: String, val droppedMark: String = "")

    /**
     * 要讀游標前多少字（UTF-16）：要蓋得住整段上一段，才比得出「游標前就是它的結尾」。
     * 同 Mac AXAdapter（上一段長度＋8，最多 4096）；最少照舊讀 200。
     */
    fun beforeWindow(previous: Previous?): Int = ((previous?.text?.length ?: 0) + 8).coerceIn(MIN_WINDOW, MAX_WINDOW)

    /**
     * 這一段前面要插的前綴：""、" "、「，」或「、」，永遠不是「。」。
     * [before]＝插入前游標前的文字（讀不到＝null → 不插）；[next]＝這一段（已經整理、拿掉句尾標點的版本）。
     * 這一段是空的就什麼都不插：只插一個「，」會留在欄位裡，復原也收不回（沒有插入就沒有復原）。
     */
    fun prefix(before: String?, previous: Previous?, next: String): String {
        if (next.isEmpty()) return ""
        return SentenceMood.joinPrefix(before, previous?.text, next, previous?.droppedMark)
    }

    /**
     * 這一段插入之後要記的「上一段」。[droppedMark] 要用送出前的文字算（同 Mac：finish 之前先算 finishDroppedMark），
     * 拿掉了什麼只有那時看得到。什麼都沒插就沿用原本的（下一段還是接在原本那段後面）。
     */
    fun remember(previous: Previous?, inserted: String, droppedMark: String): Previous? =
        if (inserted.isEmpty()) previous else Previous(inserted, droppedMark)

    /** 背景智慧整理把剛插入的 [inserted] 換成 [corrected]：記的是它就跟著換（文字與拿掉的標點都換成整理版的）。 */
    fun afterRefine(previous: Previous?, inserted: String, corrected: String, correctedMark: String): Previous? =
        if (previous?.text == inserted) Previous(corrected, correctedMark) else previous

    private const val MIN_WINDOW = 200
    private const val MAX_WINDOW = 4096
}
