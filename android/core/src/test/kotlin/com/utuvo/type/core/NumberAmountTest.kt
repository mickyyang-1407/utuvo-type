package com.utuvo.type.core

import kotlin.test.assertEquals
import kotlin.test.Test

/** 2026-10-19 真人錄音：金額規則從千分位逗號後面開始讀，「12,000塊」變「12,0塊」。同 Swift NumberNormalizationTests。 */
class NumberAmountTest {
    @Test
    fun formattedAmountFollowedByCurrencyIsUntouched() {
        assertEquals("金額是12,000塊", Normalizer.normalizeNumbers("金額是12,000塊"))
        assertEquals("先付105,000元", Normalizer.normalizeNumbers("先付105,000元"))
        assertEquals("總共1,250塊", Normalizer.normalizeNumbers("總共一千兩百五十塊"))
    }
}
