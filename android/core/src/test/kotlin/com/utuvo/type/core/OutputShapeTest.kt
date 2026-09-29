package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/** 同 Swift OutputShapeTests.testSingleLineJoinsParagraphs。 */
class OutputShapeTest {
    @Test
    fun singleLineJoinsParagraphs() {
        assertEquals("第一段。另外第二段。", OutputShape.singleLine("第一段。\n\n另外第二段。"))
        assertEquals("今天有三件事第一買牛奶第二回email。", OutputShape.singleLine("今天有三件事\n第一買牛奶\n第二回email。"))
        assertEquals("Done. Next we ship.", OutputShape.singleLine("Done.\n\nNext we ship."))
        assertEquals("Hi,謝謝", OutputShape.singleLine("Hi,\n\n謝謝"))
        assertEquals("沒有換行", OutputShape.singleLine("沒有換行"))
    }
}
