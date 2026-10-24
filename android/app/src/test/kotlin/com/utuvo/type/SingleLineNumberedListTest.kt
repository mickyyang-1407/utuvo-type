package com.utuvo.type

import android.text.InputType
import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import com.utuvo.type.core.OutputShape
import com.utuvo.type.core.SentenceMood
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 單行框不出編號清單（2026-10-22 W2-6 修正）：鍵盤聽寫走 Dictation.clean(numberedLists = FieldShape.allowsNumberedLists(inputType))，
 * 單行框收成一行後是「我買了兩個：1. 紅的 2. 藍的」，比整理前的逗號句難讀，照舊輸出頓號寫法。
 */
class SingleLineNumberedListTest {
    private val singleLine = InputType.TYPE_CLASS_TEXT
    private val multiLine = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE

    /** 鍵盤送出前的同一串：整理 → 句尾語氣 → 單行框收成一行（fitField）。 */
    private fun typedInto(inputType: Int, s: String): String {
        val cleaned = Normalizer(NormalizerOptions(numberedLists = FieldShape.allowsNumberedLists(inputType))).normalize(s).cleaned
        val toned = SentenceMood.apply(cleaned)
        return if (FieldShape.allowsLineBreaks(inputType)) toned else OutputShape.singleLine(toned)
    }

    @Test
    fun onlyFieldsThatTakeLineBreaksGetNumberedLists() {
        assertFalse(FieldShape.allowsNumberedLists(singleLine))
        assertTrue(FieldShape.allowsNumberedLists(multiLine))
        assertTrue(FieldShape.allowsNumberedLists(InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_IME_MULTI_LINE))
        assertTrue("沒有欄位資訊照多行處理", FieldShape.allowsNumberedLists(null))
    }

    @Test
    fun singleLineFieldKeepsTheCommaForm() {
        val s = "幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。"
        assertEquals("幫我準備四樣東西，播放器、耳機、線材、還有轉接頭。", typedInto(singleLine, s))
        assertFalse(typedInto(singleLine, "接下來有三件事,第一是把low end收乾淨,第二是把delay收短,第三是重做母帶").contains("1. "))
        assertTrue(typedInto(multiLine, s).contains("\n1. 播放器"))
    }
}
