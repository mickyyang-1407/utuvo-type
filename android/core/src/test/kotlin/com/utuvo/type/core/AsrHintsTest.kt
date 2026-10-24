package com.utuvo.type.core

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 辨識提示詞的字形與排序（fx-hints）：Swift `BuiltInVocabularyTests` 同一批案例。
 * 以前整串跑 ICU Hans-Hant，已經是繁體的個人詞會被轉壞（周杰倫→周傑倫、干擾→乾擾、奇岩站→奇巖站）。
 */
class AsrHintsTest {
    private val productNames = listOf("UTUVO Type", "UTUVO")
    private val noSimplified: (String) -> String = { error("不該轉簡體：$it") }

    private fun openCC(s: String): String {
        loadDictionaries.value
        return TraditionalFixer.fix(s)
    }

    @Test
    fun traditionalHintsKeepTraditionalPersonalEntries() {
        val personal = listOf("周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "邀请码")
        val hints = AsrHints.hints(personal, productNames, emptyList(), HintScript.TRADITIONAL, 100, ::openCC, noSimplified)
        assertEquals(listOf("周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "邀請碼",
                            "UTUVO Type", "UTUVO"), hints)
    }

    /** 簡體寫的按詞轉（OpenCC），不是逐字：周杰伦→周杰倫（ICU 會給周傑倫）、干扰→干擾（ICU 給乾擾）。同 Mac App 測試。 */
    @Test
    fun simplifiedEntriesConvertWordByWord() {
        val hints = AsrHints.hints(listOf("周杰伦", "干扰", "后来"), productNames, emptyList(), HintScript.TRADITIONAL, 3,
                                   ::openCC, noSimplified)
        assertEquals(listOf("周杰倫", "干擾", "後來"), hints)
    }

    @Test
    fun onlySimplifiedPersonalEntriesReachTheConverter() {
        val converted = mutableListOf<String>()
        val hints = AsrHints.hints(
            listOf("周杰倫", "干擾", "奇岩站", "于美人", "后里", "邀请码", "周杰伦", "Atmos", "頭前庄站"), productNames,
            listOf("淡水站", "奇岩站", "頭前庄站", "混音", "Typeless"), HintScript.TRADITIONAL, 100,
            toTraditional = { converted += it; "〔$it〕" }, toSimplified = noSimplified)
        assertEquals(listOf("邀请码", "周杰伦"), converted)
        assertEquals(listOf("周杰倫", "干擾", "奇岩站", "于美人", "后里", "〔邀请码〕", "〔周杰伦〕", "Atmos", "頭前庄站",
                            "UTUVO Type", "UTUVO", "淡水站", "混音"), hints, "內建包不轉、照樣去重、Typeless 不送")
    }

    /** 簡體輸出：有繁體專用字的詞（個人＋內建包）才交給繁轉簡；簡體、兩邊通用、英文都原樣。 */
    @Test
    fun simplifiedScriptOnlyConvertsTermsWithTraditionalOnlyCharacters() {
        val converted = mutableListOf<String>()
        val hints = AsrHints.hints(listOf("邀请码", "楊敏奇", "周杰伦"), productNames,
                                   listOf("雙連站", "奇岩站", "混音", "母帶", "Pro Tools"), HintScript.SIMPLIFIED, 100,
                                   toTraditional = { error("不該轉繁體：$it") },
                                   toSimplified = { converted += it; "〔$it〕" })
        assertEquals(listOf("楊敏奇", "雙連站", "母帶"), converted)
        assertEquals(listOf("邀请码", "〔楊敏奇〕", "周杰伦", "UTUVO Type", "UTUVO", "〔雙連站〕", "奇岩站", "混音", "〔母帶〕",
                            "Pro Tools"), hints)
    }

    @Test
    fun asIsKeepsEverythingAndLimitIsRespected() {
        val hints = AsrHints.hints(listOf("", "邀请码", "A1"), productNames, listOf("Dolby Atmos", "Typeless", "Atmos"),
                                   HintScript.AS_IS, 5, { error(it) }, { error(it) })
        assertEquals(listOf("邀请码", "A1", "UTUVO Type", "UTUVO", "Dolby Atmos"), hints)
        assertEquals(emptyList(), AsrHints.hints(listOf("A1"), productNames, emptyList(), HintScript.AS_IS, 0, { it }, { it }))
        assertEquals(listOf("Typeless"), AsrHints.hints(listOf("Typeless"), emptyList(), listOf("Typeless"),
                                                        HintScript.AS_IS, 10, { it }, { it }), "使用者自己加的照送")
    }

    @Test
    fun hanScriptTellsSimplifiedFromTraditionalAndShared() {
        for (term in listOf("邀请码", "周杰伦", "头发", "后来", "范晓萱", "为什么", "干扰", "体育")) {
            assertTrue(HanScript.isSimplified(term), term)
        }
        for (term in listOf("周杰倫", "干擾", "奇岩站", "范瑋琪", "于美人", "后里", "干貝", "頭前庄站", "台北", "雇主", "杰克",
                            "沉默", "疱疹", "邀請码", "Atmos", "")) {
            assertFalse(HanScript.isSimplified(term), term)
        }
        assertTrue(HanScript.hasTraditionalOnly("雙連站"))
        assertFalse(HanScript.hasTraditionalOnly("奇岩站"))
        assertTrue(HanScript.simplifiedOnly.size > 2_000)
        assertTrue(HanScript.traditionalOnly.size > 3_000)
    }

    companion object {
        private val loadDictionaries = lazy {
            val dir = System.getProperty("utuvo.opencc")?.let(::File)
            check(dir != null && dir.isDirectory) { "utuvo.opencc 沒設或不是資料夾（core/build.gradle.kts 應該有設）" }
            TraditionalFixer.configure(TraditionalFixer.directorySource(dir))
        }
    }
}
