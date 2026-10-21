package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CleanupRetryAfterTest {
    @Test
    fun parsesDelayAndHttpDate() {
        assertEquals(3_000L, CleanupRetryAfter.milliseconds("3", nowMillis = 0))
        assertEquals(10_000L, CleanupRetryAfter.milliseconds("Thu, 01 Jan 1970 00:00:10 GMT", nowMillis = 0))
        assertEquals(0L, CleanupRetryAfter.milliseconds("-3", nowMillis = 0))
        assertNull(CleanupRetryAfter.milliseconds("invalid", nowMillis = 0))
    }
}
