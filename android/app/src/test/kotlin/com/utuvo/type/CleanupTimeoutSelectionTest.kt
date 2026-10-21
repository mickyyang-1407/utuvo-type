package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 整理等待上限選哪一條路徑（2026-10-14 合併衝突的驗收）。
 *
 * 背景：iOS 那邊已經犯過一次——本機模型的等待上限被雲端的 10 秒蓋掉，
 * Pixel 實測熱機就要 9–11 秒、CPU 18–21 秒，結果每次都逾時等不到結果。
 * Android 這邊同樣要分開：有 key 用雲端 4–10 秒，沒 key 用手機上 8–20 秒（CPU 最多 60 秒）。
 */
class CleanupTimeoutSelectionTest {

    private val longSentence = "今天我們要討論三個重點".repeat(6)   // > 56 字，雲端已達 10 秒上限
    private val shortSentence = "開會"

    @Test
    fun cloudPathUsesTheShortCeilingOfTenSeconds() {
        // 有 key：走雲端，上限 ≤ 10 秒。
        val short = SmartCleanup.cleanupTimeoutMs(shortSentence, onDevice = false)
        val long = SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = false)
        assertEquals(SmartCleanup.timeoutMsFor(shortSentence), short)
        assertEquals(SmartCleanup.timeoutMsFor(longSentence), long)
        assertEquals(4_000L, short)
        assertEquals(10_000L, long)
        assertTrue("cloud timeout must stay within 10 s", long <= 10_000L)
    }

    @Test
    fun onDevicePathIsNeverCappedAtTenSeconds() {
        // 沒 key：走手機上的模型，同一句話的上限必須比雲端長。
        val short = SmartCleanup.cleanupTimeoutMs(shortSentence, onDevice = true)
        val long = SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = true)
        assertEquals(SmartCleanup.onDeviceTimeoutMs(shortSentence), short)
        assertEquals(SmartCleanup.onDeviceTimeoutMs(longSentence), long)
        assertTrue("on-device timeout must exceed the cloud ceiling", long > 10_000L)
        assertTrue("on-device timeout must be longer than cloud for the same text",
            long > SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = false))
    }

    @Test
    fun cpuOnlyPhonesGetTheWidenedCeiling() {
        val gpu = SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = true, cpuOnly = false)
        val cpu = SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = true, cpuOnly = true)
        assertEquals(SmartCleanup.onDeviceTimeoutMs(longSentence, cpuOnly = true), cpu)
        assertTrue("CPU-only must be the more generous path", cpu > gpu)
        assertTrue("CPU-only ceiling is 60 s", cpu <= 60_000L)
        // cpuOnly 對雲端路徑不該有任何影響。
        assertEquals(SmartCleanup.timeoutMsFor(longSentence),
            SmartCleanup.cleanupTimeoutMs(longSentence, onDevice = false, cpuOnly = true))
    }
}
