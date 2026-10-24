package com.utuvo.type

import com.utuvo.type.core.VoiceModes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * delivery-learning-5（一般聽寫／翻譯的一鍵復原）與 modes-5（選取改寫的復原、選取變了不覆蓋）。
 * 復原能不能做一律用既有的 [VoiceModes.undoStillApplies]，這裡驗「記下來的東西」對不對。
 */
class VoiceUndoPlanTest {

    /** 模擬輸入框：游標永遠在結尾。 */
    private class Field(var text: String) {
        val cursor get() = text.length
        fun commit(s: String) { text += s }
        /** 照 UTUVOImeService.undoVoiceEdit 的步驟復原；回傳有沒有做。（游標永遠在結尾＝沒有選取。） */
        fun undo(record: VoiceUndo): Boolean {
            val before = text.takeLast(record.rewritten.length)
            if (!VoiceUndoPlan.canUndo(record, before, cursor, cursor)) return false
            text = text.dropLast(record.rewritten.length) + record.original
            return true
        }
    }

    // ── 一般聽寫 ──

    @Test
    fun `一般聽寫插入之後可以一鍵收回`() {
        val field = Field("會議改到")
        field.commit("明天下午三點")
        val record = VoiceUndoPlan.forDictation("", "明天下午三點", field.cursor, chainId = 1, previousDictation = null)
        assertNotNull(record)
        assertTrue(record!!.chip)
        assertTrue(field.undo(record))
        assertEquals("會議改到", field.text)
    }

    @Test
    fun `接續補的前綴跟著一起收回`() {
        // W2-7：前綴只會是 ""、空白、「，」「、」（永遠不是「。」）。上一段「如果明天下雨的話，」貼上時拿掉了「，」；
        // 緊接著再講，先補回「，」再貼這段——復原要連「，」一起收，記的上一段（含拿掉的標點）也要還原。
        val previous = DictationJoin.Previous("如果明天下雨的話", "，")
        val field = Field("如果明天下雨的話")
        field.commit("，")
        field.commit("我們就改到室內")
        val record = VoiceUndoPlan.forDictation("，", "我們就改到室內", field.cursor, chainId = 2, previousDictation = previous)!!
        assertEquals("，我們就改到室內", record.rewritten)
        assertEquals(previous, record.previousDictation)
        assertTrue(field.undo(record))
        assertEquals("不能留下一個多出來的「，」", "如果明天下雨的話", field.text)
    }

    @Test
    fun `沒貼任何字就不給復原`() {
        assertNull(VoiceUndoPlan.forDictation("", "", 0, chainId = 1, previousDictation = null))
        assertNull(VoiceUndoPlan.forDictation("，", "", 3, chainId = 1, previousDictation = DictationJoin.Previous("abc")))
    }

    @Test
    fun `使用者接著打了字就不復原`() {
        val field = Field("")
        field.commit("明天見")
        val record = VoiceUndoPlan.forDictation("", "明天見", field.cursor, chainId = 1, previousDictation = null)!!
        field.commit("！")
        assertFalse(field.undo(record))
        assertEquals("明天見！", field.text)
    }

    // ── 背景智慧整理換字之後 ──

    /** 照 CorrectionChain.swap 的步驟換字（純邏輯那一半）。 */
    private fun swap(field: Field, chain: CorrectionChain, id: Long, corrected: String): Boolean {
        val plan = CorrectionChain.plan(chain.entries, id, corrected, field.text) ?: return false
        field.text = field.text.dropLast(plan.previous.length) + plan.current
        chain.applied(plan, corrected)
        return true
    }

    @Test
    fun `整理換字之後復原收回的是換過的文字`() {
        val field = Field("我到了")
        val chain = CorrectionChain()
        field.commit("，")
        field.commit("今天開會")
        val id = chain.add("今天開會", prefix = "，")
        var record = VoiceUndoPlan.forDictation("，", "今天開會", field.cursor, id, DictationJoin.Previous("我到了", "，"))
        assertTrue(swap(field, chain, id, "今天開會。"))
        assertEquals("我到了，今天開會。", field.text)
        // 沒跟著更新的話：游標位置與結尾文字都對不上，按了復原沒作用（這就是要修的）。
        assertFalse(Field(field.text).undo(record!!))
        record = VoiceUndoPlan.afterRefine(record, id, "今天開會。", field.cursor)
        assertEquals("，今天開會。", record!!.rewritten)
        assertTrue(field.undo(record))
        assertEquals("我到了", field.text)
    }

    @Test
    fun `前一段換字時只更新位置`() {
        val field = Field("")
        val chain = CorrectionChain()
        field.commit("第一段")
        val first = chain.add("第一段")
        field.commit("第二段")
        val second = chain.add("第二段")
        val record = VoiceUndoPlan.forDictation("", "第二段", field.cursor, second, DictationJoin.Previous("第一段"))
        assertTrue(swap(field, chain, first, "第1段，"))
        assertEquals("第1段，第二段", field.text)
        val updated = VoiceUndoPlan.afterRefine(record, first, "第1段，", field.cursor)!!
        assertEquals("文字沒變（換的是前一段）", "第二段", updated.rewritten)
        assertEquals(field.cursor, updated.insertEnd)
        assertTrue(field.undo(updated))
        assertEquals("第1段，", field.text)
    }

    @Test
    fun `後面那段換字不動記錄`() {
        val record = VoiceUndo("第一段", "", 3, chainId = 1, chip = true)
        assertSame(record, VoiceUndoPlan.afterRefine(record, swappedId = 2, corrected = "x", newInsertEnd = 9))
    }

    @Test
    fun `不是聽寫的復原不跟著換字`() {
        val edit = VoiceUndo("改寫結果", "原文", 10)
        assertSame(edit, VoiceUndoPlan.afterRefine(edit, swappedId = 1, corrected = "x", newInsertEnd = 3))
        assertNull(VoiceUndoPlan.afterRefine(null, swappedId = 1, corrected = "x", newInsertEnd = 3))
    }

    @Test
    fun `換字後讀不到游標就擋下復原，不刪錯字`() {
        val record = VoiceUndo("今天開會", "", 4, chainId = 5, chip = true)
        val updated = VoiceUndoPlan.afterRefine(record, 5, "今天開會。", newInsertEnd = null)!!
        assertEquals(-1, updated.insertEnd)
        assertFalse(VoiceModes.undoStillApplies("今天開會。", 5, updated.insertEnd, updated.rewritten))
    }

    // ── 翻譯 ──

    @Test
    fun `翻譯插入之後可以一鍵收回`() {
        val field = Field("Hi, ")
        field.commit("see you tomorrow")
        val record = VoiceUndoPlan.forTranslation("see you tomorrow", "", field.cursor)!!
        assertTrue(record.chip)
        assertNull("翻譯不在智慧整理的換字鏈裡", record.chainId)
        assertTrue(field.undo(record))
        assertEquals("Hi, ", field.text)
    }

    @Test
    fun `翻譯取代了選取：收回時把原本選取的放回去`() {
        val field = Field("Meeting: ")   // 「明天見」被選取、翻譯取代了它
        field.commit("see you tomorrow")
        val record = VoiceUndoPlan.forTranslation("see you tomorrow", "明天見", field.cursor)!!
        assertTrue(field.undo(record))
        assertEquals("Meeting: 明天見", field.text)
    }

    @Test
    fun `翻譯是空的不給復原`() {
        assertNull(VoiceUndoPlan.forTranslation("", "", 0))
    }

    // ── 選取改寫（modes-5）──

    @Test
    fun `選取沒變才取代`() {
        assertTrue(VoiceUndoPlan.selectionUnchanged("下午三點開會", "下午三點開會"))
        // 宿主回報的選取帶前後空白：照 trim 過的比（開始錄音時存的就是 trim 過的）。
        assertTrue(VoiceUndoPlan.selectionUnchanged("下午三點開會", " 下午三點開會\n"))
    }

    @Test
    fun `選取在改寫期間變了就不覆蓋`() {
        assertFalse("使用者改了選取的內容", VoiceUndoPlan.selectionUnchanged("下午三點開會", "下午四點開會"))
        assertFalse("選了別的地方", VoiceUndoPlan.selectionUnchanged("下午三點開會", "晚餐"))
        assertFalse("取消了選取", VoiceUndoPlan.selectionUnchanged("下午三點開會", null))
        assertFalse("取消了選取", VoiceUndoPlan.selectionUnchanged("下午三點開會", ""))
        assertFalse("一開始就沒有選取", VoiceUndoPlan.selectionUnchanged("", ""))
    }

    @Test
    fun `選取改寫之後復原放回原樣的選取`() {
        val field = Field("備註：")
        val selectionRaw = " 下午三點開會 "      // 宿主的選取原樣（含空白）
        field.commit("會議改到下午三點")         // commitText 取代選取
        val record = VoiceUndoPlan.forSelectionEdit("會議改到下午三點", selectionRaw, field.cursor)!!
        assertFalse("改寫的復原是卡片，不是頂列小鈕", record.chip)
        assertTrue(field.undo(record))
        assertEquals("一字不少（含空白）放回去", "備註： 下午三點開會 ", field.text)
    }

    @Test
    fun `改寫結果或原選取是空的不給復原`() {
        assertNull(VoiceUndoPlan.forSelectionEdit("", "原文", 3))
        assertNull(VoiceUndoPlan.forSelectionEdit("結果", "", 3))
    }

    // ── 復原之前使用者又選了一段（verify r2 low）──

    /**
     * 有選取的輸入框，照 InputConnection 的語意（服務靠的就是這兩條）：
     * deleteSurroundingText(n, 0) 刪**選取起點前**的 n 個字、不動選取；commitText 取代目前的選取。
     */
    private class SelField(var text: String, var selStart: Int = text.length, var selEnd: Int = selStart) {
        fun commit(s: String) {
            text = text.substring(0, selStart) + s + text.substring(selEnd)
            selStart += s.length
            selEnd = selStart
        }
        fun select(start: Int, end: Int) { selStart = start; selEnd = end }
        /** 照 UTUVOImeService.undoVoiceEdit：選取起點前的字 → [VoiceUndoPlan.canUndo] → 刪掉剛寫的、補回原文。 */
        fun undo(record: VoiceUndo): Boolean {
            val n = record.rewritten.length
            val before = text.substring(maxOf(0, selStart - n), selStart)
            if (!VoiceUndoPlan.canUndo(record, before, selStart, selEnd)) return false
            text = text.substring(0, selStart - n) + text.substring(selStart)
            selStart -= n; selEnd -= n
            if (record.original.isNotEmpty()) commit(record.original)
            return true
        }
    }

    @Test
    fun `選取改寫之後使用者選了緊接在後面的一段：不復原、不蓋掉他選的字`() {
        val field = SelField("會議 下午三點 在三樓", selStart = 3, selEnd = 7)   // 選了「下午三點」
        val selectionRaw = field.text.substring(3, 7)
        field.commit("下午四點")                                                 // 改寫取代選取
        val record = VoiceUndoPlan.forSelectionEdit("下午四點", selectionRaw, field.selStart)!!
        field.select(record.insertEnd, field.text.length)                        // 又選了「 在三樓」（從插入結尾開始）
        assertFalse(field.undo(record))
        assertEquals("他選的「 在三樓」一字不少", "會議 下午四點 在三樓", field.text)
        // 對照：選取收起來（游標回到插入結尾）就照常復原。
        field.select(record.insertEnd, record.insertEnd)
        assertTrue(field.undo(record))
        assertEquals("會議 下午三點 在三樓", field.text)
    }

    @Test
    fun `翻譯取代選取之後又選了一段：不復原`() {
        val field = SelField("Meeting: 明天見 at 3", selStart = 9, selEnd = 12)   // 選了「明天見」
        val replaced = field.text.substring(9, 12)
        field.commit("see you tomorrow")
        val record = VoiceUndoPlan.forTranslation("see you tomorrow", replaced, field.selStart)!!
        field.select(record.insertEnd, field.text.length)
        assertFalse(field.undo(record))
        assertEquals("Meeting: see you tomorrow at 3", field.text)
    }

    @Test
    fun `聽寫之後又選了一段：不復原`() {
        val field = SelField("")
        field.commit("明天見")
        val record = VoiceUndoPlan.forDictation("", "明天見", field.selStart, chainId = 1, previousDictation = null)!!
        field.text += "，掰"
        field.select(record.insertEnd, field.text.length)
        assertFalse(field.undo(record))
        assertEquals("明天見，掰", field.text)
    }

    @Test
    fun `反向選取（終點在前）也不復原`() {
        val record = VoiceUndo("下午四點", "下午三點", insertEnd = 7)
        assertFalse(VoiceUndoPlan.canUndo(record, "下午四點", selectionStart = 10, selectionEnd = 7))
        assertFalse(VoiceUndoPlan.canUndo(record, "下午四點", selectionStart = 7, selectionEnd = 3))
        assertTrue("對照：沒有選取", VoiceUndoPlan.canUndo(record, "下午四點", selectionStart = 7, selectionEnd = 7))
        assertFalse("讀不到位置", VoiceUndoPlan.canUndo(record, "下午四點", selectionStart = -1, selectionEnd = -1))
    }

    // ── 宿主報不出游標位置（getExtractedText 回 null，verify r2 low）──

    @Test
    fun `報不出游標位置就不出現復原小鈕`() {
        assertNull(VoiceUndoPlan.forDictation("", "明天見", -1, chainId = 1, previousDictation = null))
        assertNull(VoiceUndoPlan.forDictation(" ", "you there", -1, chainId = 2, previousDictation = DictationJoin.Previous("I'm here")))
        assertNull(VoiceUndoPlan.forTranslation("see you tomorrow", "", -1))
        assertNull(VoiceUndoPlan.forTranslation("see you tomorrow", "明天見", -1))
        // 對照：報得出位置就照常給。
        assertNotNull(VoiceUndoPlan.forDictation("", "明天見", 3, chainId = 1, previousDictation = null))
        assertNotNull(VoiceUndoPlan.forTranslation("see you tomorrow", "", 16))
    }
}
