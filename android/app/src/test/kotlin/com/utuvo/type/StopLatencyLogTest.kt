package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 按停到辨識完成（同 iOS `StopLatencyLogTests`）。 */
class StopLatencyLogTest {
    @Test fun medianOddEvenAndEarlyCount() {
        assertNull(StopLatencyLog.summarize(emptyList()))
        assertEquals(StopLatencyLog.Summary(900, 3, 2), StopLatencyLog.summarize(listOf("1800,0", "611,1", "900,1")))
        assertEquals(StopLatencyLog.Summary(750, 2, 0), StopLatencyLog.summarize(listOf("600,0", "900,0")))
    }

    @Test fun junkRowsIgnoredAndOnlyLastTwentyKept() {
        assertEquals(StopLatencyLog.Summary(500, 1, 1), StopLatencyLog.summarize(listOf("abc", "1,2,3", "500,1", "")))
        var rows = emptyList<String>()
        for (i in 1..25) rows = StopLatencyLog.append(rows, i * 100L, i % 2 == 0)
        assertEquals(20, rows.size)
        assertEquals("600,1", rows.first())
        assertEquals("0,0", StopLatencyLog.append(emptyList(), -5, false).single())
    }
}
