package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * asr-vocab-2 接線（2026-10-22，同 Mac AppModelVocabularyTests）：智慧整理回來的文字過了把關，再補套使用者的
 * 「英文專名＋個人字典」。bench：本機版已經修成「DAMI music」，模型讀原始逐字稿又寫回「Darmy Music」。
 */
class SmartCleanupVocabularyTest {
    private val dictionary = mapOf("DAMI music" to "")
    private fun packTerms(ids: List<String>) = VocabularyPacks.all.filter { it.id in ids }.flatMap { it.terms }.distinct()
    private fun terms(ids: List<String>, dict: Map<String, String> = dictionary) =
        VocabularyPacks.latinTermsForCleanedText(dict, packTerms(ids), emptyList())

    private val heard = "我在 Darmy Music 用 Utuvo Type 寫歌詞。"
    private val fixed = "我在 DAMI music 用 UTUVO Type 寫歌詞。"

    @Test
    fun acceptedCleanupGetsPersonalSpellingBack() {
        val out = SmartCleanup.finishCleaned(heard, "我在 DAMI music 用 UTUVO Type 寫歌詞", relaxed = true,
            dictionary = dictionary, latinTerms = terms(listOf("ai", "tw")))
        assertEquals(fixed, out)
    }

    @Test
    fun correctCleanupIsByteIdentical() {
        val t = terms(listOf("ai", "tw", "audio"))
        assertEquals(fixed, SmartCleanup.finishCleaned(fixed, fixed, relaxed = true, dictionary = dictionary, latinTerms = t))
        val english = "我的 phone 拿去 shop 修了，這些 types 的 stock 都還在，I'm glad the cloud sync works."
        assertEquals(english, SmartCleanup.finishCleaned(english, english, relaxed = false, dictionary = dictionary, latinTerms = t))
        // 跟本機版同一份 DictionaryStore（沒有濾掉 key＝value 的條目）：那種條目套上去不會變。
        val same = "用 Atmos 混音，交 AIFC。"
        assertEquals(same, SmartCleanup.finishCleaned(same, same, relaxed = false,
            dictionary = mapOf("Atmos" to "Atmos"), latinTerms = t))
    }

    @Test
    fun protusIsNotPulledToUberEats() {
        val withUber = mapOf("優吃" to "Uber Eats")
        assertEquals("更新 Protus", SmartCleanup.finishCleaned("更新 Protus", "更新 Protus", relaxed = true,
            dictionary = withUber, latinTerms = terms(listOf("ai", "tw"), withUber)))
        assertEquals("更新 Pro Tools", SmartCleanup.finishCleaned("更新 Protus", "更新 Protus", relaxed = true,
            dictionary = withUber, latinTerms = terms(listOf("ai", "tw", "audio"), withUber)))
    }

    @Test
    fun gateStillJudgesTheModelOutputBeforeVocabulary() {
        val wrong = runCatching {
            SmartCleanup.finishCleaned("總共是12,500塊，Darmy Music", "總共是1,250塊，DAMI music", relaxed = true,
                dictionary = dictionary, latinTerms = terms(listOf("ai")))
        }
        assertTrue(wrong.exceptionOrNull() is SmartCleanup.Rejected)
    }

    @Test
    fun cleanedTextTermsKeepPersonalProductAndOnlyPhrases() {
        val t = terms(listOf("ai", "tw", "audio"), mapOf("DAMI music" to "", "bad" to "Canonical Fixture"))
        assertEquals(listOf("DAMI music", "Canonical Fixture", "UTUVO Type", "UTUVO"), t.take(4))
        for (term in listOf("Claude Code", "Pro Tools", "Spatial Audio")) assertTrue(term, t.contains(term))
        for (term in listOf("Claude", "iPhone", "Typeless", "AIFC", "bad")) assertFalse(term, t.contains(term))
        assertEquals(listOf("UTUVO Type", "UTUVO"), VocabularyPacks.productNames)
    }

    @Test
    fun audioPackHasBenchTerms() {
        val audio = VocabularyPacks.all.first { it.id == "audio" }
        for (term in listOf("Spatial Audio", "AIFF", "AIFC", "Tonmeister", "Pro Tools")) assertTrue(term, audio.terms.contains(term))
        assertFalse("audio 預設關（同 iOS／Mac）", audio.defaultOn)
    }
}
