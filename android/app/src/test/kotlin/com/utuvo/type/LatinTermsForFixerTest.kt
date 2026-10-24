package com.utuvo.type

import com.utuvo.type.core.Normalizer
import com.utuvo.type.core.NormalizerOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * asr-vocab-v2（Android）：英文專名修正的比對目標要包含「詞彙」模式（輸出寫法留空）的個人詞。
 * 修之前用 `dictionary.values`，空字串被濾掉，Atmos 從沒進過這張表（iOS 09-25 已修）。
 */
class LatinTermsForFixerTest {

    @Test
    fun vocabularyOnlyEntryUsesTheWordItself() {
        val terms = VocabularyPacks.latinTermsForFixer(mapOf("Atmos" to ""), emptyList(), emptyList())
        assertTrue(terms.contains("Atmos"))
        assertFalse("空字串不能進比對表", terms.contains(""))
    }

    @Test
    fun replacementEntryStillUsesItsOutput() {
        // 「聽到→改成」：比對目標是改成的寫法，不是聽錯的那個（同舊行為、同 iOS）。
        val terms = VocabularyPacks.latinTermsForFixer(mapOf("pro tool" to "Pro Tools"), emptyList(), emptyList())
        assertEquals(listOf("Pro Tools"), terms)
    }

    @Test
    fun nonLatinAndDuplicateTermsAreDropped() {
        val terms = VocabularyPacks.latinTermsForFixer(
            linkedMapOf("母帶" to "", "Atmos" to "", "atmos" to "Atmos"), listOf("Atmos", "Pro Tools"), listOf("LUFS"))
        assertEquals(listOf("Atmos", "Pro Tools", "LUFS"), terms)
    }

    @Test
    fun personalTermsRuleMatchesHints() {
        assertEquals(listOf("Atmos", "Pro Tools"),
            VocabularyPacks.personalTerms(linkedMapOf("Atmos" to "", "pro tool" to "Pro Tools")))
    }

    @Test
    fun normalizerFixesMisheardVocabularyOnlyWord() {
        val terms = VocabularyPacks.latinTermsForFixer(mapOf("Atmos" to ""), emptyList(), emptyList())
        val fixed = Normalizer(NormalizerOptions(latinTerms = terms)).normalize("我用 Atmus 混").cleaned
        assertTrue("實際：$fixed", fixed.contains("Atmos"))
        assertFalse(fixed.contains("Atmus"))
        // 沒有這個詞時不亂改（舊行為）。
        val untouched = Normalizer(NormalizerOptions(latinTerms = emptyList())).normalize("我用 Atmus 混").cleaned
        assertTrue("實際：$untouched", untouched.contains("Atmus"))
    }

    private fun packTerms(ids: List<String>) = VocabularyPacks.all.filter { it.id in ids }.flatMap { it.terms }.distinct()

    /**
     * FX-5：Dictation.clean（第一次貼上）用整包詞當修正目標，修之前 phone→iPhone、shop→Zhipu、types→Typeless、
     * stock→SDK、glad／cloud→Claude（前兩萬個常用英文字改壞 295 個）。護欄在 core LatinNameFixer，這裡驗接線。
     */
    @Test
    fun firstPasteLeavesCommonEnglishAloneWithFullPacks() {
        for (ids in listOf(listOf("ai", "tw"), listOf("ai", "tw", "audio"))) {
            val terms = VocabularyPacks.latinTermsForFixer(emptyMap(), packTerms(ids), emptyList())
            for (spoken in listOf("我的 phone 拿去 shop 修了，這些 types 的 stock 都還在", "I'm glad the cloud sync works")) {
                assertEquals("$ids", spoken, Dictation.cleanLocalized(spoken, emptyMap(), terms))
            }
            // 不是英文字的照修
            assertEquals("我在測試 Gemini 的東西", Dictation.cleanLocalized("我在測試 Gimani 的東西", emptyMap(), terms))
        }
        val audio = VocabularyPacks.latinTermsForFixer(emptyMap(), packTerms(listOf("ai", "tw", "audio")), emptyList())
        assertEquals("這首要做 Spatial Audio 版本", Dictation.cleanLocalized("這首要做 Special Audio 版本", emptyMap(), audio))
    }

    /** 個人字典的明確替換（cloud→Claude）照樣套：修正器不先把 cloud 拉走，字典那一關才對得到。 */
    @Test
    fun explicitDictionaryEntryStillApplies() {
        val dictionary = mapOf("cloud" to "Claude")
        val terms = VocabularyPacks.latinTermsForFixer(dictionary, packTerms(listOf("ai", "tw")), emptyList())
        assertEquals("I'm glad the Claude sync works", Dictation.cleanLocalized("I'm glad the cloud sync works", dictionary, terms))
    }

    /**
     * W2-1 verifier：兩個個人詞折成同一個寫法（Dami Music／DAMI music）時修正器先到先得。英文專名用的個人詞照 key 的
     * code point 排（Mac `VocabularyPacks.personalTerms` 同一個順序），不跟字典插入順序走，兩個平台結果才固定、一致。
     */
    @Test
    fun personalTermOrderIsFixedAndMatchesMac() {
        for (insertion in listOf(listOf("Dami Music", "DAMI music"), listOf("DAMI music", "Dami Music"))) {
            val dictionary = LinkedHashMap<String, String>().apply { for (k in insertion) put(k, "") }
            assertEquals("$insertion", listOf("DAMI music", "Dami Music"), VocabularyPacks.personalTermsInKeyOrder(dictionary))
            assertEquals("$insertion", listOf("DAMI music", "Dami Music"),
                VocabularyPacks.latinTermsForFixer(dictionary, emptyList(), emptyList()).take(2))
            val cleaned = VocabularyPacks.latinTermsForCleanedText(dictionary, emptyList(), emptyList())
            assertEquals("$insertion", listOf("DAMI music", "Dami Music"), cleaned.take(2))
            assertEquals("$insertion", "我在 DAMI music 上課", Normalizer.applyVocabulary("我在 dami music 上課", dictionary, cleaned))
        }
        // 提示詞（biasing／cloudHints）照舊用插入順序
        assertEquals(listOf("b", "a"), VocabularyPacks.personalTerms(linkedMapOf("b" to "", "a" to "")))
        // 補充平面的字照 code point 排（U+FF21 在 U+1D400 前面；String.compareTo 的 UTF-16 順序剛好相反）
        assertEquals(listOf("\uFF21x", "\uD835\uDC00x"),
            VocabularyPacks.personalTermsInKeyOrder(linkedMapOf("\uD835\uDC00x" to "", "\uFF21x" to "")))
    }
}
