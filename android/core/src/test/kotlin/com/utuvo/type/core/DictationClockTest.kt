package com.utuvo.type.core

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * 聽寫秒數（2026-10-13 修補項 1）：秒數在**停止聽寫的那一刻**算好，
 * 交付（雲端重辨識／翻譯）晚多久都不能影響，也不會變回 0。
 */
class DictationClockTest {
    private val t0 = 1_700_000_000_000L   // 固定起點，測試不碰真實時鐘

    @Test
    fun `停止時的秒數就是這次聽寫的秒數`() {
        // 講了 42.9 秒 → 記 42 秒
        assertEquals(42, DictationClock.freeze(t0, t0 + 42_900))
    }

    @Test
    fun `停止到交付之間的延遲不影響秒數`() {
        val stoppedAt = t0 + 42_900
        // 停止聽寫那一刻：算出 42 秒，之後起始時間就歸零。
        val seconds = DictationClock.freeze(t0, stoppedAt)
        assertEquals(42, seconds)
        // 交付晚了 30 秒（雲端重辨識／翻譯）：此時再問時鐘拿不到任何東西，
        // 交付必須用停止當下存下來的那個值——舊 bug 就是這裡去讀時鐘而得到 0。
        val deliveredAt = stoppedAt + 30_000
        assertEquals(0, DictationClock.freeze(0L, deliveredAt))
        assertEquals(true, seconds > 0)
    }

    @Test
    fun `講不到一秒也要記 1 秒不會是 0`() {
        assertEquals(1, DictationClock.freeze(t0, t0 + 300))
        assertEquals(1, DictationClock.freeze(t0, t0))
    }

    @Test
    fun `沒有在錄或時鐘倒退回 0`() {
        assertEquals(0, DictationClock.freeze(0L, t0))
        assertEquals(0, DictationClock.freeze(-1L, t0))
        assertEquals(0, DictationClock.elapsedSeconds(t0, t0 - 5_000))
    }

    @Test
    fun `elapsedSeconds 就是經過的整秒數`() {
        assertEquals(0, DictationClock.elapsedSeconds(t0, t0 + 999))
        assertEquals(1, DictationClock.elapsedSeconds(t0, t0 + 1_000))
        assertEquals(60, DictationClock.elapsedSeconds(t0, t0 + 60_999))
    }
}
