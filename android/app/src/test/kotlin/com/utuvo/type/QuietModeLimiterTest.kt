package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QuietModeLimiterTest {
    @Test
    fun belowKneePassesThroughUnchanged() {
        for (x in listOf(0f, 0.1f, -0.3f, 0.5f, -0.7f, QuietMode.LIMITER_KNEE)) {
            assertEquals(x, QuietMode.limited(x), 0f)
        }
    }

    @Test
    fun anyInputStaysStrictlyBelowCeiling() {
        for (x in listOf(0.71f, 1f, 2.5f, 10f, 1e4f, -1f, -10f, -1e4f)) {
            val y = QuietMode.limited(x)
            assertTrue("$x → $y", kotlin.math.abs(y) < QuietMode.LIMITER_CEILING)
        }
    }

    @Test
    fun monotonicContinuousAndOddSymmetric() {
        var previous = QuietMode.limited(-12f)
        var x = -12f + 0.01f
        while (x <= 12f) {
            val y = QuietMode.limited(x)
            assertTrue("not monotonic at $x", y >= previous)
            assertEquals(-y, QuietMode.limited(-x), 1e-6f)
            previous = y
            x += 0.01f
        }
        val knee = QuietMode.LIMITER_KNEE
        assertTrue(kotlin.math.abs(QuietMode.limited(knee + 1e-4f) - QuietMode.limited(knee)) < 1e-3f)
    }

    @Test
    fun hardClipWouldHaveFlattenedLoudPeaks() {
        // 2.5 倍增益下 0.6 的樣本變成 1.5：舊的 coerceIn 會把 0.5 與 0.6 都夾成 1.0（資訊全丟）；軟膝要分得開。
        val a = QuietMode.limited(0.5f * QuietMode.GAIN_QUIET)
        val b = QuietMode.limited(0.6f * QuietMode.GAIN_QUIET)
        assertTrue("$a vs $b", b > a)
    }
}
