package com.utuvo.type.core

import kotlin.test.assertEquals
import kotlin.test.Test

/** 2026-10-20 Pixel：「但是...辨識」被轉成「但是。..辨識」（第一個點當成句號）。同 Swift EllipsisPunctuationTests。 */
class EllipsisPunctuationTest {
    @Test fun chineseEllipsisBecomesFullWidth() {
        assertEquals("但是……辨識好像還是笨笨的耶", Normalizer.normalizePunctuation("但是...辨識好像還是笨笨的耶"))
        assertEquals("我想想……好了", Normalizer.normalizePunctuation("我想想…好了"))
        assertEquals("好。我知道", Normalizer.normalizePunctuation("好.我知道"))
        assertEquals("version 1.2.3", Normalizer.normalizePunctuation("version 1.2.3"))
    }
}
