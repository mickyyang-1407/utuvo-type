package com.utuvo.type

import com.utuvo.type.core.HintScript
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android 雲端辨識提示詞跟 Mac 同一條規則（fx-hints；排序與字形在 core `AsrHints`）：
 * 個人字典 → 產品名 → 音訊 → AI → 其他內建 → catalog；包內的 Typeless 不送（pn05）；已經是繁體的個人詞不轉。
 */
class CloudHintsTest {
    private fun pack(id: String) = VocabularyPacks.all.first { it.id == id }

    @Test
    fun productNamesFollowPersonalEntriesAndTypelessStaysOut() {
        val hints = VocabularyPacks.cloudHints(linkedMapOf("周杰倫" to "", "奇岩站" to ""), listOf(pack("ai"), pack("audio")),
                                               listOf("醫學種子"), HintScript.TRADITIONAL,
                                               toTraditional = { error("繁體詞不該被轉：$it") }, toSimplified = { error(it) })
        assertEquals(listOf("周杰倫", "奇岩站", "UTUVO Type", "UTUVO", "Dolby Atmos"), hints.take(5))
        assertFalse("包內的 Typeless 不送", hints.contains("Typeless"))
        assertTrue(hints.indexOf("Gemini") > hints.indexOf("AIFC"))
        assertEquals("醫學種子", hints.last())
    }

    @Test
    fun onlySimplifiedPersonalEntriesAreConverted() {
        val converted = mutableListOf<String>()
        val hints = VocabularyPacks.cloudHints(linkedMapOf("邀请码" to "", "干擾" to "", "tw" to "頭前庄站"), listOf(pack("tw")),
                                               emptyList(), HintScript.TRADITIONAL,
                                               toTraditional = { converted += it; "邀請碼" }, toSimplified = { error(it) })
        assertEquals(listOf("邀请码"), converted)
        assertEquals(listOf("邀請碼", "干擾", "頭前庄站", "UTUVO Type", "UTUVO", "淡水站"), hints.take(6))
        assertTrue("內建站名原樣送", hints.contains("奇岩站"))
        assertTrue(hints.size <= 200)
    }

    @Test
    fun hintScriptFollowsDictationVariant() {
        val zh = DictationLanguage.TRADITIONAL_CHINESE
        assertEquals(HintScript.TRADITIONAL, VocabularyPacks.hintScript(zh, LanguageVariant.ZH_TW))
        assertEquals(HintScript.TRADITIONAL, VocabularyPacks.hintScript(zh, LanguageVariant.ZH_HK))
        assertEquals(HintScript.SIMPLIFIED, VocabularyPacks.hintScript(zh, LanguageVariant.ZH_CN))
        assertEquals(HintScript.SIMPLIFIED, VocabularyPacks.hintScript(DictationLanguage.SIMPLIFIED_CHINESE, LanguageVariant.DEFAULT))
        assertEquals(HintScript.TRADITIONAL, VocabularyPacks.hintScript(zh, LanguageVariant.DEFAULT))
        assertEquals(HintScript.AS_IS, VocabularyPacks.hintScript(DictationLanguage.ENGLISH, LanguageVariant.EN_US))
        assertEquals(HintScript.AS_IS, VocabularyPacks.hintScript(DictationLanguage.JAPANESE, LanguageVariant.DEFAULT))
    }
}
