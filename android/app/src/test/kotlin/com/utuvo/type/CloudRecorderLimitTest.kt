package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * capture-latency-3：錄音上限（正式版 300 秒，這裡縮成 10 秒、上限前 3 秒提醒）。
 *
 * 修之前：最後一批整批讀進來寫超過陣列尾端，丟例外 → 整段錄音被當成失敗清空；到上限也沒有任何通知，
 * 麥克風沒放、鍵盤還顯示聆聽中。假來源跑的是正式版同一個錄音迴圈（[CloudRecorder.startWithSource]）。
 */
class CloudRecorderLimitTest {
    private val sr = 16_000

    /** 講話聲（±3000）；最多給 [total] 個樣本，之後回 0（＝麥克風沒有新資料）。 */
    private class Source(private val total: Int) {
        val fed = AtomicInteger(0)
        fun read(buffer: ShortArray, size: Int): Int {
            val left = total - fed.get()
            if (left <= 0) { Thread.sleep(2); return 0 }
            val n = minOf(size, left)
            for (i in 0 until n) buffer[i] = if (i % 2 == 0) 3000 else -3000
            fed.addAndGet(n)
            return n
        }
    }

    @Test
    fun limitStopsByItselfKeepsAllSamplesAndNotifiesOnce() {
        val recorder = CloudRecorder(maxSeconds = 10, warningSeconds = 3)
        val source = Source(total = 15 * sr)          // 上限 + 5 秒
        val warnings = AtomicInteger(0)
        val fedAtWarning = AtomicInteger(-1)
        val reached = AtomicInteger(0)
        val done = CountDownLatch(1)
        recorder.onLimitWarning = { warnings.incrementAndGet(); fedAtWarning.set(source.fed.get()) }
        recorder.onLimitReached = { reached.incrementAndGet(); done.countDown() }
        recorder.startWithSource(source::read)

        assertTrue("錄滿上限要自己通知", done.await(5, TimeUnit.SECONDS))
        assertFalse("錄滿就自己停", recorder.isActive)
        assertTrue(recorder.limitReached)
        assertTrue("樣本還沒取走", recorder.hasSamplesToClaim)
        assertEquals(1, warnings.get())
        assertEquals(1, reached.get())
        // 提醒在上限前 3 秒（第 7 秒）那一批觸發。
        val at = fedAtWarning.get()
        assertTrue("提醒時已錄 $at 個樣本", at >= 7 * sr && at < 7 * sr + 2048)
        assertEquals("上限之後不再讀麥克風", 10 * sr, source.fed.get())

        val samples = recorder.stop()
        assertEquals("整段 10 秒都要留著給雲端", 10 * sr, samples.size)
        assertTrue(samples.all { it != 0f })
        assertFalse("取一次就沒了：第二次收尾不能再清掉或再取", recorder.hasSamplesToClaim)
    }

    @Test
    fun stopBeforeLimitBehavesAsBefore() {
        val recorder = CloudRecorder(maxSeconds = 10, warningSeconds = 3)
        val source = Source(total = 2 * sr)
        val warnings = AtomicInteger(0)
        val reached = AtomicInteger(0)
        recorder.onLimitWarning = { warnings.incrementAndGet() }
        recorder.onLimitReached = { reached.incrementAndGet() }
        assertFalse(recorder.hasSamplesToClaim)
        recorder.startWithSource(source::read)
        assertTrue(recorder.hasSamplesToClaim)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (source.fed.get() < 2 * sr && System.nanoTime() < deadline) Thread.sleep(5)

        val samples = recorder.stop()
        assertEquals(2 * sr, samples.size)
        assertFalse(recorder.limitReached)
        assertFalse(recorder.hasSamplesToClaim)
        assertFalse(recorder.isActive)
        assertEquals(0, warnings.get())
        assertEquals(0, reached.get())
    }

    @Test
    fun cancelAfterLimitDropsSamples() {
        val recorder = CloudRecorder(maxSeconds = 2, warningSeconds = 1)
        val done = CountDownLatch(1)
        recorder.onLimitReached = { done.countDown() }
        recorder.startWithSource(Source(total = 5 * sr)::read)
        assertTrue(done.await(5, TimeUnit.SECONDS))
        assertTrue(recorder.hasSamplesToClaim)
        recorder.cancel()
        assertFalse("放棄＝不能再有樣本被送出去", recorder.hasSamplesToClaim)
        assertEquals(0, recorder.stop().size)
    }
}
