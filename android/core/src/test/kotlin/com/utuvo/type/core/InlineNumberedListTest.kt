package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertNotNull

class InlineNumberedListTest {
    private val raw = "好，我來測試看看明天的錄音要帶 1.麥克風 2.輔駕 3.腳架 4.個人監聽器 5.耳機還有最重要的 6.耳朵"
    private val expected = "好，我來測試看看明天的錄音要帶：\n1. 麥克風\n2. 輔駕\n3. 腳架\n4. 個人監聽器\n5. 耳機\n6. 還有最重要的耳朵"

    @Test fun explicitListPreservesContentAndEmphasis() {
        assertEquals(expected, OutputShape.expandingInlineNumberedList(raw))
        assertEquals(expected, OutputShape.expandingInlineNumberedList(expected))
        assertNull(CleanupFidelity.rejectionReason(raw, expected))
        for (lost in listOf("耳機", "最重要的", "個人監聽器")) {
            assertNotNull(CleanupFidelity.rejectionReason(raw, expected.replace(lost, "")))
        }
    }

    @Test fun ambiguousOrAlreadyStructuredInputStaysUntouched() {
        for (text in listOf("版本1.2與2.3", "費用1.5元，另付2.5元", "1. 麥克風", "1. 麥克風 3. 耳機",
            "1. 麥克風 1. 耳機", "1. 2. 耳機", "`1. 麥克風 2. 耳機`", "1. 麥克風\n2. 耳機")) {
            assertEquals(text, OutputShape.expandingInlineNumberedList(text))
        }
    }

    @Test fun valuesNegationAndOutputOrdinalsStayProtected() {
        val source = "交付 1. 48K 2. -14 LUFS 3. 不要耳機"
        val formatted = OutputShape.expandingInlineNumberedList(source)
        assertNull(CleanupFidelity.rejectionReason(source, formatted))
        for ((from, to) in listOf("48K" to "96K", "-14" to "14", "不要" to "要", "2. " to "9. ")) {
            assertNotNull(CleanupFidelity.rejectionReason(source, formatted.replace(from, to)))
        }
    }
}
