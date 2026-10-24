package com.utuvo.type

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * capture-latency-1（Android 半邊）：雲端最後一段按停當下就開跑，不等系統辨識器交回最終結果。
 * 系統文字只當退路；系統什麼都沒聽到時不能為了快把唯一的結果丟掉（不設時限再送一次）。
 * 不打網路：工作是假的。
 */
class EarlyCloudFinishTest {

    private val thread = Executor { r -> Thread(r, "early-test").apply { isDaemon = true }.start() }

    @Test
    fun `建立的當下就開跑，不等任何人來拿`() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        EarlyCloudFinish(thread) { started.countDown(); release.await(); "雲端文字" }
        // 還沒有人呼叫 await（＝系統辨識器的最終結果還沒到），雲端已經在跑了。
        assertTrue("按停當下雲端就要開跑", started.await(2, TimeUnit.SECONDS))
        release.countDown()
    }

    @Test
    fun `雲端有結果就用雲端的`() {
        val finish = EarlyCloudFinish(thread) { "明天下午三點" }
        var rescued = 0
        assertEquals("明天下午三點", finish.await(raw = "明天下午3點") { rescued++; "x" })
        assertEquals(0, rescued)
    }

    @Test
    fun `雲端放棄、系統有文字：回 null 讓呼叫端貼系統文字，不再送一次`() {
        val finish = EarlyCloudFinish(thread) { null }
        var rescued = 0
        assertNull(finish.await(raw = "明天下午3點") { rescued++; "x" })
        assertEquals(0, rescued)
    }

    @Test
    fun `雲端放棄、系統什麼都沒聽到：不設時限再送一次`() {
        val finish = EarlyCloudFinish(thread) { null }
        assertEquals("救回來的文字", finish.await(raw = "") { "救回來的文字" })
    }

    @Test
    fun `背景那一份自己丟例外：當成雲端沒結果`() {
        val finish = EarlyCloudFinish(thread) { throw IllegalStateException("boom") }
        assertNull(finish.await(raw = "系統文字") { "x" })
        assertEquals("y", EarlyCloudFinish(thread) { throw IllegalStateException("boom") }.await(raw = "") { "y" })
    }

    @Test
    fun `取消之後回 null，也不救援`() {
        val started = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val finish = EarlyCloudFinish(thread) {
            started.countDown()
            try { Thread.sleep(10_000); "太晚了" } catch (e: InterruptedException) { interrupted.countDown(); null }
        }
        assertTrue(started.await(2, TimeUnit.SECONDS))
        finish.cancel()
        assertTrue(finish.isCancelled)
        val rescues = AtomicInteger()
        assertNull(finish.await(raw = "") { rescues.incrementAndGet(); "x" })
        assertEquals("按了 ✕ 或換了輸入框：不能再打一次網路", 0, rescues.get())
        assertTrue("背景那一份要被中斷，不能讓網路白跑", interrupted.await(2, TimeUnit.SECONDS))
    }

    @Test
    fun `工作只跑一次`() {
        val runs = AtomicInteger()
        val finish = EarlyCloudFinish(thread) { runs.incrementAndGet(); "a" }
        assertEquals("a", finish.await("") { null })
        assertEquals("a", finish.await("") { null })
        assertEquals(1, runs.get())
        assertFalse(finish.isCancelled)
    }
}
