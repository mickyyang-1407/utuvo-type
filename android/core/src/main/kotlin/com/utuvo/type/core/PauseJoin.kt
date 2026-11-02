package com.utuvo.type.core

/**
 * 兩段辨識結果在「停頓」處接起來時，中間要不要補一個「，」（2026-11-01）。
 *
 * 雲端辨識邊錄邊傳（`ChunkedASR` 在 ≥0.6 秒的停頓切段）、系統辨識器一停頓就交回一段（ContinuousDictation），
 * 段落邊界本身就是停頓；以前中文段落直接黏起來，停頓的資訊整個丟掉。講超過七、八十字、
 * 智慧整理又沒有成功替換時，貼出來的就是一長串沒有標點的字（Micky 2026-11-01 iPhone／Android 回報）。
 *
 * 規則跟 iOS `PausePunctuator`（裝置端辨識依停頓補標點）同一套，而且只會更保守：
 * - 停頓只補逗號，永遠不補句號（2026-09-24「一休息就出現句點」；W2-7「一句話被切成兩句」）；
 * - 兩邊都是中文字、邊界沒有標點才補；英數字照舊由呼叫端補空白；
 * - 前一小句（最後一個標點之後）不到 [MIN_CLAUSE] 個字＝講話中的遲疑，不補；
 * - 前一段停在「到／把／的／然後…」這種後面一定還有話的字，不補；
 * - 下一段開頭是語助詞（「了」「吧」…＝前一句的尾巴），不補；
 * - 前一段停在中文數字、下一段接數字或單位（「三百」＋「五十萬元」），是同一個數字講到一半，不補（2026-11-02 審查）。
 *
 * 純函式，iOS `ChunkedASR.pauseMark` 逐條對應，兩邊同一組案例。
 */
object PauseJoin {
    /** 同 iOS `PausePunctuator.minClause`。 */
    const val MIN_CLAUSE = 6

    /** 同 iOS `PausePunctuator.danglingEndings`。 */
    val danglingEndings = listOf(
        "到", "在", "去", "從", "往", "跟", "和", "與", "把", "被", "給", "對", "向", "換成", "前往", "搭", "坐",
        "還有", "因為", "如果", "而且", "但是", "所以", "然後", "就是",
        "再", "很", "最", "比較", "一個", "這個", "那個", "可能", "應該", "已經", "正在", "先", "都", "也", "還", "的",
    )

    /** 同 Normalizer 的 sentenceParticles。 */
    private const val PARTICLES = "了啦喔哦吧呢嗎吗呀啊囉嘛耶欸哈"

    /** 中文數字與位數（同 iOS `ChunkedASR.pauseDigits`）。 */
    const val DIGITS = "零〇一二兩两三四五六七八九十百千萬万億亿"

    /** 只會接在數字後面的單位（同 iOS `ChunkedASR.pauseUnits`）。「公」「分」不收：「公司」「分別」是一般的話。 */
    const val UNITS = "元塊块個个歲岁倍年月日號号%％"

    /** 前一段停在數字上：最後一個字是中文數字，或「三點」這種「數字＋點」（「晚一點」的「一點」是「一些」，不算）。 */
    fun endsWithNumber(a: String): Boolean {
        val last = a.lastOrNull() ?: return false
        if (DIGITS.indexOf(last) >= 0) return true
        if (last != '點' && last != '点' || a.length < 2) return false
        val previous = a[a.length - 2]
        return previous != '一' && DIGITS.indexOf(previous) >= 0
    }

    /** 下一段是同一個數字的後半：單位、「半」、或數字（「一」開頭要後面還是數字／單位，「一起」「一定」不算）。 */
    fun startsNumberContinuation(b: String): Boolean {
        val first = b.firstOrNull() ?: return false
        if (UNITS.indexOf(first) >= 0 || first == '半') return true
        if (DIGITS.indexOf(first) < 0) return false
        if (first != '一') return true
        val second = b.getOrNull(1) ?: return false
        return DIGITS.indexOf(second) >= 0 || UNITS.indexOf(second) >= 0 || "點点半".indexOf(second) >= 0
    }

    /** [previous] 與 [next] 在停頓處相接時要插的標點：「，」或空字串。 */
    fun mark(previous: String, next: String): String {
        val a = previous.trimEnd()
        val b = next.trimStart()
        if (a.isEmpty() || b.isEmpty()) return ""
        val last = a.last()
        val first = b.first()
        if (!isHan(last) || !isHan(first)) return ""
        if (PARTICLES.indexOf(first) >= 0) return ""
        if (endsWithNumber(a) && startsNumberContinuation(b)) return ""
        if (danglingEndings.any(a::endsWith)) return ""
        if (clauseLength(a.takeLastWhile { !isPunctuation(it) }) < MIN_CLAUSE) return ""
        return "，"
    }

    /** 這一小句有幾個字：中文一字一個，英數字一個詞一個（同 iOS `PausePunctuator.clauseLength`）。 */
    fun clauseLength(s: String): Int {
        var n = 0
        var inWord = false
        for (c in s) {
            if (c.code < 128 && c.isLetterOrDigit()) {
                if (!inWord) { n += 1; inWord = true }
            } else {
                inWord = false
                if (!c.isWhitespace() && !isPunctuation(c)) n += 1
            }
        }
        return n
    }

    private fun isHan(c: Char): Boolean = c in '㐀'..'鿿'

    private fun isPunctuation(c: Char): Boolean = !c.isLetterOrDigit() && !c.isWhitespace()
}
