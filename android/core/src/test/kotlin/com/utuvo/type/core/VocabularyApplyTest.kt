package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

/** 與 Swift VocabularyApplyTests 同一批案例（asr-vocab-2）：只補套英文專名＋個人字典，而且冪等。 */
class VocabularyApplyTest {
    @Test fun appliesDictionaryAndLatinNamesWithoutTouchingLayout() {
        val out = Normalizer.applyVocabulary("1. 用優土佛 Type 匯出\n2. 更新 Protus", mapOf("優土佛" to "UTUVO"), listOf("Pro Tools", "UTUVO"))
        assertEquals("1. 用UTUVO Type 匯出\n2. 更新 Pro Tools", out)
    }

    @Test fun formattedParagraphWithoutHitsIsUnchanged() {
        val text = "老師你好，\n\n1. 明天下午 3 點開會。\n2. 帶 Atmos 母帶。\n\n謝謝！"
        assertEquals(text, Normalizer.applyVocabulary(text, mapOf("優土佛" to "UTUVO"), listOf("Pro Tools", "UTUVO")))
    }

    @Test fun doesNotInsertWrongBrandFromSkeleton() {
        val out = Normalizer.applyVocabulary("更新 Protus", mapOf("優吃" to "Uber Eats"), listOf("Uber Eats"))
        assertFalse(out.contains("Uber Eats"), out)
        assertEquals("更新 Protus", out)
    }

    @Test fun isIdempotentWhenValueContainsKey() {
        val dict = mapOf("UTUVO" to "UTUVO Type")
        assertEquals("UTUVO Type", Normalizer.applyVocabulary("UTUVO Type", dict, emptyList()))
        assertEquals("我在用 UTUVO Type 打字", Normalizer.applyVocabulary("我在用 UTUVO Type 打字", dict, emptyList()))
        val once = Normalizer.applyVocabulary("UTUVO 很好用", dict, emptyList())
        assertEquals("UTUVO Type 很好用", once)
        assertEquals(once, Normalizer.applyVocabulary(once, dict, emptyList()))
    }

    @Test fun valueWithKeyInTheMiddleIsAlsoIdempotent() {
        val dict = mapOf("Atmos" to "Dolby Atmos")
        assertEquals("用 Dolby Atmos 混音", Normalizer.applyVocabulary("用 Dolby Atmos 混音", dict, emptyList()))
        assertEquals("用 Dolby Atmos 混音", Normalizer.applyVocabulary("用 Atmos 混音", dict, emptyList()))
    }

    @Test fun instanceMethodUsesOptions() {
        val n = Normalizer(NormalizerOptions(dictionary = mapOf("優土佛" to "UTUVO"), latinTerms = listOf("Pro Tools")))
        assertEquals("更新 Pro Tools，UTUVO", n.applyVocabulary("更新 Protus，優土佛"))
    }

    // 智慧整理後補套的英文專名目標（asr-vocab-2 接線）：與 Swift VocabularyApplyTests 同一批案例。

    private val packSample = listOf("Claude", "Gemini", "Typeless", "iPhone", "Zhipu", "SDK", "commit",
        "Claude Code", "Pro Tools", "Uber Eats", "Spatial Audio")
    private val personal = listOf("DAMI music", "UTUVO Type", "UTUVO")

    @Test fun cleanedTextTermsKeepPersonalAndOnlyMultiWordPackTerms() {
        val terms = Normalizer.latinTermsForCleanedText(personal + listOf("", "DAMI music"), packSample)
        assertEquals(listOf("DAMI music", "UTUVO Type", "UTUVO", "Claude Code", "Pro Tools", "Uber Eats", "Spatial Audio"), terms)
        assertEquals(emptyList(), Normalizer.latinTermsForCleanedText(emptyList(), emptyList()))
    }

    @Test fun cleanedTextFixesNamesTheModelMisspelled() {
        val terms = Normalizer.latinTermsForCleanedText(personal, packSample)
        val out = Normalizer.applyVocabulary("我在 Darmy Music 用 Utuvo Type 寫歌詞，要做 Special Audio 版本。", emptyMap(), terms)
        assertEquals("我在 DAMI music 用 UTUVO Type 寫歌詞，要做 Spatial Audio 版本。", out)
        assertEquals(out, Normalizer.applyVocabulary(out, emptyMap(), terms))
    }

    @Test fun cleanedTextLeavesCorrectEnglishAndCorrectNamesByteIdentical() {
        val terms = Normalizer.latinTermsForCleanedText(personal, packSample)
        for (text in listOf("I'm glad the cloud sync works.", "My phone is in the shop, these types of stock commits are fine.",
            "我在 DAMI music 用 UTUVO Type 打字，Claude 跟 Gemini 都試過。", "1. 匯出 AIFC\n2. 用 Pro Tools 混音")) {
            assertEquals(text, Normalizer.applyVocabulary(text, mapOf("優土佛" to "UTUVO"), terms))
        }
    }

    @Test fun cleanedTextDoesNotPullProtusToUberEats() {
        val terms = Normalizer.latinTermsForCleanedText(personal, packSample.filter { it != "Pro Tools" })
        assertEquals("更新 Protus", Normalizer.applyVocabulary("更新 Protus", emptyMap(), terms))
    }
}
