package com.utuvo.type

import org.junit.Assert.*
import org.junit.Test

/** The same finishCleaned function is used by cloud and local production requests. */
class PortablePolishContractTest {
    @Test fun approvedVocabularyFixesMishearingsWithOneProviderIndependentVerdict() {
        val source = "我用 Dolbe Edmos 在 Protuos 混音"
        val candidate = "我用 Dolby Atmos 在 Pro Tools 混音。"
        val dictionary = mapOf("Dolby Atmos" to "", "Pro Tools" to "")
        for (legacyRelaxed in listOf(false, true)) {
            assertEquals(candidate, SmartCleanup.finishCleaned(candidate, source, legacyRelaxed,
                dictionary, listOf("Dolby Atmos", "Pro Tools")))
        }
    }
    @Test fun contrastsNumbersAndNegationCannotBeReversedByAnyProvider() {
        val cases = listOf(
            "我住三樓，不是四樓" to "我住四樓。",
            "我要48K不是96K" to "我要96K。",
            "金額是1,250塊" to "金額是12,500塊。",
            "我不會寄給他" to "我會寄給他。")
        for ((source, wrong) in cases) for (legacyRelaxed in listOf(false, true)) {
            assertTrue(source, runCatching {
                SmartCleanup.finishCleaned(wrong, source, legacyRelaxed)
            }.exceptionOrNull() is SmartCleanup.Rejected)
        }
        for (source in listOf("我住三樓，不是四樓", "我要48K不是96K")) {
            val actual = SmartCleanup.finishCleaned(source + "。", source, false)
            assertTrue(actual, actual.contains("不是"))
        }
    }
    @Test fun approvedDictionaryDoesNotReplaceChineseWordFragments() {
        val source = "蘋果派和軟體工程師"
        val result = SmartCleanup.finishCleaned(source, source, false,
            mapOf("蘋果" to "Apple", "軟體" to "Software"), emptyList())
        assertEquals(source, result)
    }
}
