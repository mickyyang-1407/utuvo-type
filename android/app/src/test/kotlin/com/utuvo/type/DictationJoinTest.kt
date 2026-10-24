package com.utuvo.type

import com.utuvo.type.core.SentenceMood
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * W2-7（2026-10-22）：Android 鍵盤的接續聽寫改用 Mac 同一條規則（[DictationJoin]／SentenceMood.joinPrefix）。
 * 照 UTUVOImeService.deliver 的步驟在一個模擬輸入框裡一段一段貼，驗欄位最後長怎樣、復原收得乾不乾淨。
 */
class DictationJoinTest {

    /** 模擬輸入框（游標永遠在結尾）＋鍵盤記的上一段，步驟照 UTUVOImeService.deliver／undoVoiceEdit。 */
    private class Keyboard(var text: String = "", val kind: FieldToneHint.Kind = FieldToneHint.Kind.DOCUMENT) {
        var last: DictationJoin.Previous? = null
        var undo: VoiceUndo? = null
        /** 宿主讀不到游標前（getTextBeforeCursor 回 null）。 */
        var readable = true
        val chain = CorrectionChain()

        /** 一段辨識結果（已經過 Dictation.clean／SpeechPunctuation）送進來；回傳這次插的前綴。 */
        fun deliver(restored: String): String {
            val droppedMark = SentenceMood.finishDroppedMark(restored)
            val cleaned = FieldToneHint.apply(SentenceMood.apply(restored), kind)   // fitField（沒有換行時不必 singleLine）
            val previous = last
            val before = if (readable) text.takeLast(DictationJoin.beforeWindow(previous)) else null
            val prefix = DictationJoin.prefix(before, previous, cleaned)
            text += prefix + cleaned
            last = DictationJoin.remember(previous, cleaned, droppedMark)
            val id = chain.add(cleaned, prefix)
            undo = VoiceUndoPlan.forDictation(prefix, cleaned, text.length, id, previous)
            return prefix
        }

        fun undoLast(): Boolean {
            val record = undo ?: return false
            undo = null
            if (!VoiceUndoPlan.canUndo(record, text.takeLast(record.rewritten.length), text.length, text.length)) return false
            text = text.dropLast(record.rewritten.length) + record.original
            record.chainId?.let { chain.remove(it); last = record.previousDictation }
            return true
        }
    }

    // ── 規則一、二：永遠不補「。」；中文接中文什麼都不插 ──

    @Test
    fun `講到一半停住的兩段接成一句不插句號`() {
        for ((a, b, joined) in listOf(
            Triple("我要。", "一杯咖啡。", "我要一杯咖啡"),
            Triple("我的老闆。", "明天要來。", "我的老闆明天要來"),
            Triple("我想要", "一杯咖啡", "我想要一杯咖啡"),
            Triple("因為下雨", "所以取消", "因為下雨所以取消"),
            Triple("我到了。", "你在哪？", "我到了你在哪？"),
            Triple("你在哪？", "我到了。", "你在哪？我到了"),
            Triple("我到了", "OK 我們走", "我到了OK 我們走"),
            Triple("價格是100", "元", "價格是100元"),
        )) {
            val k = Keyboard()
            assertEquals("", k.deliver(a))
            assertEquals("$a＋$b", "", k.deliver(b))
            assertEquals("$a＋$b", joined, k.text)
            assertFalse("$a＋$b：永遠不補句號", k.text.removePrefix(a.removeSuffix("。")).startsWith("。"))
        }
    }

    // ── 規則三：英數字（或 .!?,;:）接英數字補一個空白 ──

    @Test
    fun `英數字接英數字補一個空白`() {
        for ((a, b, joined) in listOf(
            Triple("I want", "a coffee.", "I want a coffee."),
            Triple("Done.", "Next step", "Done. Next step"),
            Triple("room 42", "3 people", "room 42 3 people"),
            Triple("Hello world,", "again", "Hello world, again"),
            Triple("Sounds good", "我們走", "Sounds good我們走"),
            Triple("I am here.", "我在門口", "I am here.我在門口"),
        )) {
            val k = Keyboard()
            k.deliver(a)
            k.deliver(b)
            assertEquals("$a＋$b", joined, k.text)
        }
    }

    // ── 規則四：上一段被拿掉的「，」「、」補回去（「。」不補） ──

    @Test
    fun `上一段拿掉的逗號頓號補回去`() {
        val k = Keyboard()
        k.deliver("如果明天下雨的話，")
        assertEquals("送出時拿掉了「，」", "如果明天下雨的話", k.text)
        assertEquals(DictationJoin.Previous("如果明天下雨的話", "，"), k.last)
        assertEquals("，", k.deliver("我們就改到室內。"))
        assertEquals("如果明天下雨的話，我們就改到室內", k.text)

        val list = Keyboard()
        list.deliver("蘋果、")
        assertEquals("、", list.deliver("香蕉"))
        assertEquals("蘋果、香蕉", list.text)

        val english = Keyboard()
        english.deliver("取樣率用96k，")
        assertEquals("「，」優先於英數字之間的空白", "，", english.deliver("48k也可以"))
        assertEquals("取樣率用96k，48k也可以", english.text)
    }

    /** 記下的標點一定是 fitField 真的拿掉的那一個（FieldToneHint.apply＝dropFinalPeriod，哪種欄位都一樣）。 */
    @Test
    fun `記下的標點就是送出前拿掉的那一個`() {
        val samples = listOf("如果明天下雨的話，", "蘋果、", "我要。", "我要", "你明天會來嗎。", "Hello world,", "Done.",
            "第一段。\n第二段，", "，", "好， \u0301", "好，\r\n", "①，", "🙂，")
        for (kind in FieldToneHint.Kind.values()) {
            for (raw in samples) {
                val applied = SentenceMood.apply(raw)
                val toned = FieldToneHint.apply(applied, kind)
                val mark = SentenceMood.finishDroppedMark(raw)
                assertEquals("$kind「$raw」", SentenceMood.finish(raw), toned)
                if (toned == applied) {
                    assertEquals("$kind「$raw」沒拿東西就不記", "", mark)
                } else {
                    assertTrue("$kind「$raw」記的是「，」「、」「。」之一", mark in setOf("，", "、", "。"))
                    // 拿掉的就是原文裡最後一個這種標點（後面只剩空白）：從原文刪掉它正好是送出的文字。
                    val at = applied.lastIndexOf(mark)
                    assertEquals("$kind「$raw」", toned, applied.removeRange(at, at + mark.length))
                }
            }
        }
    }

    // ── 規則五：讀不到游標前、游標前是空白、游標移走：什麼都不插 ──

    @Test
    fun `游標前不是上一段的結尾就什麼都不插`() {
        val unreadable = Keyboard()
        unreadable.deliver("如果明天下雨的話，")
        unreadable.readable = false
        assertEquals("讀不到游標前", "", unreadable.deliver("我們就改到室內"))

        val spaced = Keyboard()
        spaced.deliver("如果明天下雨的話，")
        spaced.text += " "
        assertEquals("游標前是空白", "", spaced.deliver("我們就改到室內"))
        assertEquals("如果明天下雨的話 我們就改到室內", spaced.text)

        val moved = Keyboard()
        moved.deliver("I want")
        moved.text += "ed"
        assertEquals("使用者自己打了字", "", moved.deliver("a coffee"))

        val other = Keyboard("別的欄位的字")
        other.last = DictationJoin.Previous("蘋果", "、")
        assertEquals("換了欄位", "", other.deliver("香蕉"))
    }

    @Test
    fun `這一段是空的就不插也不忘記上一段`() {
        val k = Keyboard()
        k.deliver("如果明天下雨的話，")
        assertEquals("", k.deliver(""))
        assertEquals("如果明天下雨的話", k.text)
        assertNull("沒插東西就沒有復原", k.undo)
        assertEquals(DictationJoin.Previous("如果明天下雨的話", "，"), k.last)
        assertEquals("，", k.deliver("我們就改到室內"))
    }

    /** 上一段很長（超過以前固定讀的 200 字）：同 Mac 讀上一段長度＋8，才比得出游標前就是它的結尾。 */
    @Test
    fun `上一段很長也接得上`() {
        val long = "This is a long dictation about the mix ".repeat(8).trim()
        assertTrue(long.length > 200)
        val k = Keyboard()
        k.deliver(long)
        assertEquals(" ", k.deliver("and then"))
        assertEquals("$long and then", k.text)
        assertEquals(200, DictationJoin.beforeWindow(null))
        assertEquals(200, DictationJoin.beforeWindow(DictationJoin.Previous("短")))
        assertEquals(long.length + 8, DictationJoin.beforeWindow(DictationJoin.Previous(long)))
        assertEquals(4096, DictationJoin.beforeWindow(DictationJoin.Previous("x".repeat(10_000))))
    }

    // ── 一鍵復原：前綴可能是 ""、" "、「，」「、」，都要一起收回，記的上一段還原 ──

    @Test
    fun `復原收回前綴與這一段`() {
        for ((a, b, prefix) in listOf(
            Triple("如果明天下雨的話，", "我們就改到室內", "，"),
            Triple("蘋果、", "香蕉", "、"),
            Triple("I want", "a coffee", " "),
            Triple("我要", "一杯咖啡", ""),
        )) {
            val k = Keyboard()
            k.deliver(a)
            val afterFirst = k.text
            val remembered = k.last
            assertEquals(prefix, k.deliver(b))
            assertEquals(prefix + SentenceMood.finish(b), k.undo!!.rewritten)
            assertTrue(k.undoLast())
            assertEquals("$a＋$b：復原後只剩上一段", afterFirst, k.text)
            assertEquals("$a＋$b：記的上一段還原", remembered, k.last)
            assertEquals("$a＋$b：再講一次照樣接", prefix, k.deliver(b))
        }
    }

    // ── 背景智慧整理換字 ──

    @Test
    fun `整理換了上一段之後照整理版接`() {
        val inserted = "如果明天下雨"
        val previous = DictationJoin.Previous(inserted, "")
        // 整理版多了「的話，」：fitField 拿掉「，」，記下來，下一段補回。
        val result = "如果明天下雨的話，"
        val corrected = FieldToneHint.apply(SentenceMood.apply(result), FieldToneHint.Kind.DOCUMENT)
        val updated = DictationJoin.afterRefine(previous, inserted, corrected, SentenceMood.finishDroppedMark(result))
        assertEquals(DictationJoin.Previous("如果明天下雨的話", "，"), updated)
        assertEquals("，", DictationJoin.prefix("如果明天下雨的話", updated, "我們就改到室內"))
        // 換的不是記著的那一段：不動。
        assertEquals(previous, DictationJoin.afterRefine(previous, "別段", corrected, "，"))
        assertNull(DictationJoin.afterRefine(null, inserted, corrected, "，"))
    }

    /** 後面那段補了空白之後，前面那段的更正照樣換得上（CorrectionChain 把前綴算進去；以前英文接英文會永遠對不上）。 */
    @Test
    fun `補了前綴之後前一段的更正照樣換得上`() {
        val k = Keyboard()
        k.deliver("I want")
        val first = k.chain.entries.first().id
        assertEquals(" ", k.deliver("a coffee"))
        assertEquals("I want a coffee", k.text)
        val plan = CorrectionChain.plan(k.chain.entries, first, "I'd like", k.text)
        assertEquals("I want a coffee", plan!!.previous)
        assertEquals("I'd like a coffee", plan.current)
        k.text = k.text.dropLast(plan.previous.length) + plan.current
        k.chain.applied(plan, "I'd like")
        // 後面那段的復原只更新位置，照樣收得乾淨（連同空白）。
        k.undo = VoiceUndoPlan.afterRefine(k.undo, first, "I'd like", k.text.length)
        assertTrue(k.undoLast())
        assertEquals("I'd like", k.text)

        val zh = Keyboard()
        zh.deliver("如果明天下雨的話，")
        val head = zh.chain.entries.first().id
        zh.deliver("我們就改到室內")
        assertEquals("如果明天下雨的話，我們就改到室內", zh.text)
        val zhPlan = CorrectionChain.plan(zh.chain.entries, head, "要是明天下雨的話", zh.text)!!
        assertEquals("要是明天下雨的話，我們就改到室內", zhPlan.current)
    }
}
